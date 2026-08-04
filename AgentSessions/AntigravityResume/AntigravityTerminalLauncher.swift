import Foundation

@MainActor
protocol AntigravityTerminalLaunching {
    func launchInTerminal(_ package: AntigravityResumeCommandBuilder.CommandPackage) async throws
}

@MainActor
final class AntigravityTerminalLauncher: AntigravityTerminalLaunching {
    func launchInTerminal(_ package: AntigravityResumeCommandBuilder.CommandPackage) async throws {
        try AgentTerminalLauncher.launchInTerminal(shellCommand: package.shellCommand, domain: "AntigravityTerminalLauncher")
    }
}

@MainActor
final class AntigravityITermLauncher: AntigravityTerminalLaunching {
    func launchInTerminal(_ package: AntigravityResumeCommandBuilder.CommandPackage) async throws {
        try AgentTerminalLauncher.launchInITerm(shellCommand: package.shellCommand, domain: "AntigravityITermLauncher")
    }
}

@MainActor
final class AntigravityWarpLauncher: AntigravityTerminalLaunching {
    func launchInTerminal(_ package: AntigravityResumeCommandBuilder.CommandPackage) async throws {
        try await AgentTerminalLauncher.launchInWarp(shellCommand: package.displayCommand, cwd: package.workingDirectory?.path, kind: .warp)
    }
}

@MainActor
final class AntigravityWarpPreviewLauncher: AntigravityTerminalLaunching {
    func launchInTerminal(_ package: AntigravityResumeCommandBuilder.CommandPackage) async throws {
        try await AgentTerminalLauncher.launchInWarp(shellCommand: package.displayCommand, cwd: package.workingDirectory?.path, kind: .warpPreview)
    }
}

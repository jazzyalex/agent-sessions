import Foundation

@MainActor
protocol HermesTerminalLaunching {
    func launchInTerminal(_ package: HermesResumeCommandBuilder.CommandPackage) async throws
}

@MainActor
final class HermesTerminalLauncher: HermesTerminalLaunching {
    func launchInTerminal(_ package: HermesResumeCommandBuilder.CommandPackage) async throws {
        try AgentTerminalLauncher.launchInTerminal(shellCommand: package.shellCommand, domain: "HermesTerminalLauncher")
    }
}

@MainActor
final class HermesITermLauncher: HermesTerminalLaunching {
    func launchInTerminal(_ package: HermesResumeCommandBuilder.CommandPackage) async throws {
        try AgentTerminalLauncher.launchInITerm(shellCommand: package.shellCommand, domain: "HermesITermLauncher")
    }
}

@MainActor
final class HermesWarpLauncher: HermesTerminalLaunching {
    func launchInTerminal(_ package: HermesResumeCommandBuilder.CommandPackage) async throws {
        try await AgentTerminalLauncher.launchInWarp(shellCommand: package.displayCommand, cwd: package.workingDirectory?.path, kind: .warp)
    }
}

@MainActor
final class HermesWarpPreviewLauncher: HermesTerminalLaunching {
    func launchInTerminal(_ package: HermesResumeCommandBuilder.CommandPackage) async throws {
        try await AgentTerminalLauncher.launchInWarp(shellCommand: package.displayCommand, cwd: package.workingDirectory?.path, kind: .warpPreview)
    }
}

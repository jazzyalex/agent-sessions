import Foundation

@MainActor
protocol FxTerminalLaunching {
    func launchInTerminal(_ package: FxResumeCommandBuilder.CommandPackage) async throws
}

@MainActor
final class FxTerminalLauncher: FxTerminalLaunching {
    func launchInTerminal(_ package: FxResumeCommandBuilder.CommandPackage) async throws {
        try AgentTerminalLauncher.launchInTerminal(shellCommand: package.shellCommand, domain: "FxTerminalLauncher")
    }
}

@MainActor
final class FxITermLauncher: FxTerminalLaunching {
    func launchInTerminal(_ package: FxResumeCommandBuilder.CommandPackage) async throws {
        try AgentTerminalLauncher.launchInITerm(shellCommand: package.shellCommand, domain: "FxITermLauncher")
    }
}

@MainActor
final class FxWarpLauncher: FxTerminalLaunching {
    func launchInTerminal(_ package: FxResumeCommandBuilder.CommandPackage) async throws {
        try await AgentTerminalLauncher.launchInWarp(shellCommand: package.displayCommand, cwd: package.workingDirectory?.path, kind: .warp)
    }
}

@MainActor
final class FxWarpPreviewLauncher: FxTerminalLaunching {
    func launchInTerminal(_ package: FxResumeCommandBuilder.CommandPackage) async throws {
        try await AgentTerminalLauncher.launchInWarp(shellCommand: package.displayCommand, cwd: package.workingDirectory?.path, kind: .warpPreview)
    }
}

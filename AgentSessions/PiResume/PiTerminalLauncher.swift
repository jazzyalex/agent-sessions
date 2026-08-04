import Foundation

@MainActor
protocol PiTerminalLaunching {
    func launchInTerminal(_ package: PiResumeCommandBuilder.CommandPackage) async throws
}

@MainActor
final class PiTerminalLauncher: PiTerminalLaunching {
    func launchInTerminal(_ package: PiResumeCommandBuilder.CommandPackage) async throws {
        try AgentTerminalLauncher.launchInTerminal(shellCommand: package.shellCommand, domain: "PiTerminalLauncher")
    }
}

@MainActor
final class PiITermLauncher: PiTerminalLaunching {
    func launchInTerminal(_ package: PiResumeCommandBuilder.CommandPackage) async throws {
        try AgentTerminalLauncher.launchInITerm(shellCommand: package.shellCommand, domain: "PiITermLauncher")
    }
}

@MainActor
final class PiWarpLauncher: PiTerminalLaunching {
    func launchInTerminal(_ package: PiResumeCommandBuilder.CommandPackage) async throws {
        try await AgentTerminalLauncher.launchInWarp(shellCommand: package.displayCommand, cwd: package.workingDirectory?.path, kind: .warp)
    }
}

@MainActor
final class PiWarpPreviewLauncher: PiTerminalLaunching {
    func launchInTerminal(_ package: PiResumeCommandBuilder.CommandPackage) async throws {
        try await AgentTerminalLauncher.launchInWarp(shellCommand: package.displayCommand, cwd: package.workingDirectory?.path, kind: .warpPreview)
    }
}

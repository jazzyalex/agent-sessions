import Foundation

@MainActor
protocol DevinTerminalLaunching {
    func launchInTerminal(_ package: DevinResumeCommandBuilder.CommandPackage) async throws
}

@MainActor
final class DevinTerminalLauncher: DevinTerminalLaunching {
    func launchInTerminal(_ package: DevinResumeCommandBuilder.CommandPackage) async throws {
        try AgentTerminalLauncher.launchInTerminal(shellCommand: package.shellCommand, domain: "DevinTerminalLauncher")
    }
}

@MainActor
final class DevinITermLauncher: DevinTerminalLaunching {
    func launchInTerminal(_ package: DevinResumeCommandBuilder.CommandPackage) async throws {
        try AgentTerminalLauncher.launchInITerm(shellCommand: package.shellCommand, domain: "DevinITermLauncher")
    }
}

@MainActor
final class DevinWarpLauncher: DevinTerminalLaunching {
    func launchInTerminal(_ package: DevinResumeCommandBuilder.CommandPackage) async throws {
        try await AgentTerminalLauncher.launchInWarp(shellCommand: package.displayCommand, cwd: package.workingDirectory?.path, kind: .warp)
    }
}

@MainActor
final class DevinWarpPreviewLauncher: DevinTerminalLaunching {
    func launchInTerminal(_ package: DevinResumeCommandBuilder.CommandPackage) async throws {
        try await AgentTerminalLauncher.launchInWarp(shellCommand: package.displayCommand, cwd: package.workingDirectory?.path, kind: .warpPreview)
    }
}

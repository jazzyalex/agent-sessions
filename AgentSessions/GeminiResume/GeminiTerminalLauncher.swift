import Foundation

@MainActor
protocol GeminiTerminalLaunching {
    func launchInTerminal(_ package: GeminiResumeCommandBuilder.CommandPackage) throws
}

@MainActor
final class GeminiTerminalLauncher: GeminiTerminalLaunching {
    func launchInTerminal(_ package: GeminiResumeCommandBuilder.CommandPackage) throws {
        try AgentTerminalLauncher.launchInTerminal(shellCommand: package.shellCommand, domain: "GeminiTerminalLauncher")
    }
}

@MainActor
final class GeminiITermLauncher: GeminiTerminalLaunching {
    func launchInTerminal(_ package: GeminiResumeCommandBuilder.CommandPackage) throws {
        try AgentTerminalLauncher.launchInITerm(shellCommand: package.shellCommand, domain: "GeminiITermLauncher")
    }
}

@MainActor
final class GeminiWarpLauncher: GeminiTerminalLaunching {
    func launchInTerminal(_ package: GeminiResumeCommandBuilder.CommandPackage) throws {
        try AgentTerminalLauncher.launchInWarp(shellCommand: package.displayCommand, cwd: package.workingDirectory?.path, kind: .warp)
    }
}

@MainActor
final class GeminiWarpPreviewLauncher: GeminiTerminalLaunching {
    func launchInTerminal(_ package: GeminiResumeCommandBuilder.CommandPackage) throws {
        try AgentTerminalLauncher.launchInWarp(shellCommand: package.displayCommand, cwd: package.workingDirectory?.path, kind: .warpPreview)
    }
}

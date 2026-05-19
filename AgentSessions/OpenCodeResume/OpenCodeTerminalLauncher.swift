import Foundation

@MainActor
protocol OpenCodeTerminalLaunching {
    func launchInTerminal(_ package: OpenCodeResumeCommandBuilder.CommandPackage) throws
}

@MainActor
final class OpenCodeTerminalLauncher: OpenCodeTerminalLaunching {
    func launchInTerminal(_ package: OpenCodeResumeCommandBuilder.CommandPackage) throws {
        try AgentTerminalLauncher.launchInTerminal(shellCommand: package.shellCommand, domain: "OpenCodeTerminalLauncher")
    }
}

@MainActor
final class OpenCodeITermLauncher: OpenCodeTerminalLaunching {
    func launchInTerminal(_ package: OpenCodeResumeCommandBuilder.CommandPackage) throws {
        try AgentTerminalLauncher.launchInITerm(shellCommand: package.shellCommand, domain: "OpenCodeITermLauncher")
    }
}

@MainActor
final class OpenCodeWarpLauncher: OpenCodeTerminalLaunching {
    func launchInTerminal(_ package: OpenCodeResumeCommandBuilder.CommandPackage) throws {
        try AgentTerminalLauncher.launchInWarp(shellCommand: package.shellCommand, cwd: package.workingDirectory?.path, kind: .warp)
    }
}

@MainActor
final class OpenCodeWarpPreviewLauncher: OpenCodeTerminalLaunching {
    func launchInTerminal(_ package: OpenCodeResumeCommandBuilder.CommandPackage) throws {
        try AgentTerminalLauncher.launchInWarp(shellCommand: package.shellCommand, cwd: package.workingDirectory?.path, kind: .warpPreview)
    }
}

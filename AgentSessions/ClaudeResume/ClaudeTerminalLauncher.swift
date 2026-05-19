import Foundation

@MainActor
final class ClaudeTerminalLauncher: ClaudeTerminalLaunching {
    func launchInTerminal(_ package: ClaudeResumeCommandBuilder.CommandPackage) throws {
        try AgentTerminalLauncher.launchInTerminal(shellCommand: package.shellCommand, domain: "ClaudeTerminalLauncher")
    }

    func launchInITerm(_ package: ClaudeResumeCommandBuilder.CommandPackage) throws {
        try AgentTerminalLauncher.launchInITerm(shellCommand: package.shellCommand, domain: "ClaudeTerminalLauncher")
    }
}

@MainActor
final class ClaudeWarpLauncher: ClaudeTerminalLaunching {
    func launchInTerminal(_ package: ClaudeResumeCommandBuilder.CommandPackage) throws {
        try AgentTerminalLauncher.launchInWarp(shellCommand: package.shellCommand, cwd: package.workingDirectory?.path, kind: .warp)
    }
}

@MainActor
final class ClaudeWarpPreviewLauncher: ClaudeTerminalLaunching {
    func launchInTerminal(_ package: ClaudeResumeCommandBuilder.CommandPackage) throws {
        try AgentTerminalLauncher.launchInWarp(shellCommand: package.shellCommand, cwd: package.workingDirectory?.path, kind: .warpPreview)
    }
}

import Foundation

@MainActor
final class ClaudeTerminalLauncher: ClaudeTerminalLaunching {
    func launchInTerminal(_ package: ClaudeResumeCommandBuilder.CommandPackage) async throws {
        try AgentTerminalLauncher.launchInTerminal(shellCommand: package.shellCommand, domain: "ClaudeTerminalLauncher")
    }
}

@MainActor
final class ClaudeSelectedTerminalLauncher: ClaudeTerminalLaunching {
    private let terminalKind: TerminalKind

    init(terminalKind: TerminalKind) {
        self.terminalKind = terminalKind
    }

    func launchInTerminal(_ package: ClaudeResumeCommandBuilder.CommandPackage) async throws {
        try await AgentTerminalLauncher.launch(
            shellCommand: package.shellCommand,
            displayCommand: package.displayCommand,
            cwd: package.workingDirectory?.path,
            kind: terminalKind,
            domain: "ClaudeTerminalLauncher"
        )
    }
}

@MainActor
final class ClaudeWarpLauncher: ClaudeTerminalLaunching {
    func launchInTerminal(_ package: ClaudeResumeCommandBuilder.CommandPackage) async throws {
        try await AgentTerminalLauncher.launchInWarp(shellCommand: package.displayCommand, cwd: package.workingDirectory?.path, kind: .warp)
    }
}

@MainActor
final class ClaudeWarpPreviewLauncher: ClaudeTerminalLaunching {
    func launchInTerminal(_ package: ClaudeResumeCommandBuilder.CommandPackage) async throws {
        try await AgentTerminalLauncher.launchInWarp(shellCommand: package.displayCommand, cwd: package.workingDirectory?.path, kind: .warpPreview)
    }
}

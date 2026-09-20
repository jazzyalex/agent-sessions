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
final class FxSelectedTerminalLauncher: FxTerminalLaunching {
    private let terminalKind: TerminalKind

    init(terminalKind: TerminalKind) {
        self.terminalKind = terminalKind
    }

    func launchInTerminal(_ package: FxResumeCommandBuilder.CommandPackage) async throws {
        try await AgentTerminalLauncher.launch(
            shellCommand: package.shellCommand,
            displayCommand: package.displayCommand,
            cwd: package.workingDirectory?.path,
            kind: terminalKind,
            domain: "FxTerminalLauncher"
        )
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

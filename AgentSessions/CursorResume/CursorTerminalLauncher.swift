import Foundation

@MainActor
protocol CursorTerminalLaunching {
    func launchInTerminal(_ package: CursorResumeCommandBuilder.CommandPackage) throws
}

@MainActor
final class CursorTerminalLauncher: CursorTerminalLaunching {
    func launchInTerminal(_ package: CursorResumeCommandBuilder.CommandPackage) throws {
        try AgentTerminalLauncher.launchInTerminal(shellCommand: package.shellCommand, domain: "CursorTerminalLauncher")
    }
}

@MainActor
final class CursorITermLauncher: CursorTerminalLaunching {
    func launchInTerminal(_ package: CursorResumeCommandBuilder.CommandPackage) throws {
        try AgentTerminalLauncher.launchInITerm(shellCommand: package.shellCommand, domain: "CursorITermLauncher")
    }
}

@MainActor
final class CursorWarpLauncher: CursorTerminalLaunching {
    func launchInTerminal(_ package: CursorResumeCommandBuilder.CommandPackage) throws {
        try AgentTerminalLauncher.launchInWarp(shellCommand: package.shellCommand, cwd: package.workingDirectory?.path, kind: .warp)
    }
}

@MainActor
final class CursorWarpPreviewLauncher: CursorTerminalLaunching {
    func launchInTerminal(_ package: CursorResumeCommandBuilder.CommandPackage) throws {
        try AgentTerminalLauncher.launchInWarp(shellCommand: package.shellCommand, cwd: package.workingDirectory?.path, kind: .warpPreview)
    }
}

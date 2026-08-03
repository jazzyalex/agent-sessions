import Foundation

@MainActor
protocol KimiTerminalLaunching {
    func launchInTerminal(_ package: KimiResumeCommandBuilder.CommandPackage) throws
}

@MainActor
final class KimiTerminalLauncher: KimiTerminalLaunching {
    func launchInTerminal(_ package: KimiResumeCommandBuilder.CommandPackage) throws {
        try AgentTerminalLauncher.launchInTerminal(shellCommand: package.shellCommand, domain: "KimiTerminalLauncher")
    }
}

@MainActor
final class KimiITermLauncher: KimiTerminalLaunching {
    func launchInTerminal(_ package: KimiResumeCommandBuilder.CommandPackage) throws {
        try AgentTerminalLauncher.launchInITerm(shellCommand: package.shellCommand, domain: "KimiITermLauncher")
    }
}

@MainActor
final class KimiWarpLauncher: KimiTerminalLaunching {
    func launchInTerminal(_ package: KimiResumeCommandBuilder.CommandPackage) throws {
        try AgentTerminalLauncher.launchInWarp(shellCommand: package.displayCommand, cwd: package.workingDirectory?.path, kind: .warp)
    }
}

@MainActor
final class KimiWarpPreviewLauncher: KimiTerminalLaunching {
    func launchInTerminal(_ package: KimiResumeCommandBuilder.CommandPackage) throws {
        try AgentTerminalLauncher.launchInWarp(shellCommand: package.displayCommand, cwd: package.workingDirectory?.path, kind: .warpPreview)
    }
}

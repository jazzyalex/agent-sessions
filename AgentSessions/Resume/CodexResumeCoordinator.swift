import Foundation
import AppKit

protocol CodexCLIEnvironmentProviding {
    func probeVersion(customPath: String?) -> Result<CodexCLIEnvironment.ProbeResult, CodexCLIEnvironment.ProbeError>
}

extension CodexCLIEnvironment: CodexCLIEnvironmentProviding {}

@MainActor
protocol CodexTerminalLaunching {
    func launchInTerminal(_ package: CodexResumeCommandBuilder.CommandPackage) async throws
}

extension CodexResumeLauncher: CodexTerminalLaunching {}

@MainActor
final class CodexResumeCoordinator {
    enum QuickLaunchResult {
        case launched
        case needsConfiguration(String)
        case failure(String)
    }

    static let shared = CodexResumeCoordinator()

    private let settings: CodexResumeSettings
    private let environment: CodexCLIEnvironmentProviding
    private let commandBuilder: CodexResumeCommandBuilder
    private let terminalLauncher: CodexTerminalLaunching
    private let desktopLauncher: CodexDesktopAppLauncher

    init(settings: CodexResumeSettings? = nil,
         environment: CodexCLIEnvironmentProviding? = nil,
         commandBuilder: CodexResumeCommandBuilder = CodexResumeCommandBuilder(),
         terminalLauncher: CodexTerminalLaunching? = nil,
         desktopLauncher: CodexDesktopAppLauncher? = nil) {
        self.settings = settings ?? CodexResumeSettings.shared
        self.environment = environment ?? CodexCLIEnvironment()
        self.commandBuilder = commandBuilder
        self.terminalLauncher = terminalLauncher ?? CodexResumeLauncher()
        self.desktopLauncher = desktopLauncher ?? CodexDesktopAppLauncher()
    }

    static func appSessionID(for session: Session) -> String? {
        guard session.source == .codex, !session.isSideChat,
              let id = session.codexInternalSessionID ?? session.codexFilenameUUID,
              UUID(uuidString: id) != nil else { return nil }
        return id
    }

    func openInApp(session: Session) async -> QuickLaunchResult {
        guard let sessionID = Self.appSessionID(for: session) else {
            return .failure(CodexDesktopAppLauncher.LaunchError.invalidSessionID.localizedDescription)
        }
        guard FileManager.default.fileExists(atPath: session.filePath) else {
            return .failure(String(localized: "The session log could not be found on disk.",
                                   comment: "Error when opening a session whose local log was removed."))
        }
        do {
            // Desktop opening is independent of the CLI binary, version and terminal settings.
            try await desktopLauncher.openSession(sessionID: sessionID)
            return .launched
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    func quickLaunchInTerminal(session: Session) async -> QuickLaunchResult {
        guard FileManager.default.fileExists(atPath: session.filePath) else {
            return .failure("The session log could not be found on disk.")
        }

        let overridePath = settings.binaryOverride
        let env = environment
        let probe = await Task.detached { env.probeVersion(customPath: overridePath) }.value

        switch probe {
        case .failure(let error):
            return .needsConfiguration(error.errorDescription ?? "Codex CLI not found. Configure the path and try again.")
        case .success(let data):
            guard data.version.supportsResumeByID else {
                return .needsConfiguration("Codex \(data.version.description) does not support resuming by session ID. Use the resume sheet to configure a fallback path.")
            }

            do {
                let fallbackURL: URL?
                if FileManager.default.fileExists(atPath: session.filePath) {
                    fallbackURL = URL(fileURLWithPath: session.filePath)
                } else {
                    fallbackURL = nil
                }
                let package = try commandBuilder.makeCommand(for: session,
                                                              settings: settings,
                                                              binaryURL: data.binaryURL,
                                                              fallbackPath: fallbackURL,
                                                              attemptResumeFirst: true)
                switch settings.launchMode {
                case .iterm:
                    // Use a temporary launcher that targets iTerm2
                    let iterm = CodexResumeLauncher()
                    try iterm.launchInITerm(package)
                case .warp:
                    try await AgentTerminalLauncher.launchInWarp(
                        shellCommand: package.displayCommand,
                        cwd: package.workingDirectory?.path,
                        kind: .warp
                    )
                case .warpPreview:
                    try await AgentTerminalLauncher.launchInWarp(
                        shellCommand: package.displayCommand,
                        cwd: package.workingDirectory?.path,
                        kind: .warpPreview
                    )
                default:
                    try await terminalLauncher.launchInTerminal(package)
                }
                return .launched
            } catch {
                return .failure(error.localizedDescription)
            }
        }
    }
}

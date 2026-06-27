import Foundation

@MainActor
final class AntigravityResumeCoordinator {
    private let env: AntigravityCLIEnvironment
    private let builder: AntigravityResumeCommandBuilder
    private let launcher: AntigravityTerminalLaunching

    init(env: AntigravityCLIEnvironment,
         builder: AntigravityResumeCommandBuilder,
         launcher: AntigravityTerminalLaunching) {
        self.env = env
        self.builder = builder
        self.launcher = launcher
    }

    func resumeInTerminal(input: AntigravityResumeInput,
                          dryRun: Bool = false) async -> AntigravityResumeResult {
        let probe = env.probe(customPath: input.binaryOverride)
        guard case let .success(info) = probe else {
            let message: String
            switch probe {
            case .failure(.notFound):
                message = "Antigravity CLI executable not found."
            case .failure(.invalidResponse):
                message = "Failed to execute agy --version."
            case .success:
                message = "Antigravity CLI not found." // unreachable; guard ensures failure
            }
            return AntigravityResumeResult(launched: false, strategy: .none, error: message, command: nil)
        }

        let trimmedID = input.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let strategy: AntigravityResumeCommandBuilder.Strategy
        let resultStrategy: AntigravityStrategyUsed
        if info.supportsResume, let id = trimmedID, !id.isEmpty {
            strategy = .resumeByID(id: id)
            resultStrategy = .resumeByID
        } else if info.supportsResume {
            strategy = .continueRecent
            resultStrategy = .resumeByID
        } else {
            return AntigravityResumeResult(launched: false,
                                      strategy: .none,
                                      error: "Installed Antigravity CLI does not support --conversation or --continue.",
                                      command: nil)
        }

        let pkg: AntigravityResumeCommandBuilder.CommandPackage
        do {
            pkg = try builder.makeCommand(strategy: strategy, binaryURL: info.binaryURL, workingDirectory: input.workingDirectory)
        } catch {
            return AntigravityResumeResult(launched: false, strategy: resultStrategy, error: error.localizedDescription, command: nil)
        }

        if dryRun {
            return AntigravityResumeResult(launched: false, strategy: resultStrategy, error: nil, command: pkg.shellCommand)
        }

        do {
            try launcher.launchInTerminal(pkg)
            return AntigravityResumeResult(launched: true, strategy: resultStrategy, error: nil, command: pkg.shellCommand)
        } catch {
            return AntigravityResumeResult(launched: false, strategy: resultStrategy, error: error.localizedDescription, command: nil)
        }
    }
}

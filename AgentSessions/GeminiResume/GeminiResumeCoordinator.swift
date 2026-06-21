import Foundation

@MainActor
final class GeminiResumeCoordinator {
    private let env: GeminiCLIEnvironment
    private let builder: GeminiResumeCommandBuilder
    private let launcher: GeminiTerminalLaunching

    init(env: GeminiCLIEnvironment,
         builder: GeminiResumeCommandBuilder,
         launcher: GeminiTerminalLaunching) {
        self.env = env
        self.builder = builder
        self.launcher = launcher
    }

    func resumeInTerminal(input: GeminiResumeInput,
                          dryRun: Bool = false) async -> GeminiResumeResult {
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
            return GeminiResumeResult(launched: false, strategy: .none, error: message, command: nil)
        }

        let trimmedID = input.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let strategy: GeminiResumeCommandBuilder.Strategy
        let resultStrategy: GeminiStrategyUsed
        if info.supportsResume, let id = trimmedID, !id.isEmpty {
            strategy = .resumeByID(id: id)
            resultStrategy = .resumeByID
        } else if info.supportsResume {
            strategy = .continueRecent
            resultStrategy = .resumeByID
        } else {
            return GeminiResumeResult(launched: false,
                                      strategy: .none,
                                      error: "Installed Antigravity CLI does not support --conversation or --continue.",
                                      command: nil)
        }

        let pkg: GeminiResumeCommandBuilder.CommandPackage
        do {
            pkg = try builder.makeCommand(strategy: strategy, binaryURL: info.binaryURL, workingDirectory: input.workingDirectory)
        } catch {
            return GeminiResumeResult(launched: false, strategy: resultStrategy, error: error.localizedDescription, command: nil)
        }

        if dryRun {
            return GeminiResumeResult(launched: false, strategy: resultStrategy, error: nil, command: pkg.shellCommand)
        }

        do {
            try launcher.launchInTerminal(pkg)
            return GeminiResumeResult(launched: true, strategy: resultStrategy, error: nil, command: pkg.shellCommand)
        } catch {
            return GeminiResumeResult(launched: false, strategy: resultStrategy, error: error.localizedDescription, command: nil)
        }
    }
}

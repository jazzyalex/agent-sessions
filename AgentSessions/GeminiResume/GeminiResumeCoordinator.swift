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
                message = "Gemini CLI executable not found."
            case .failure(.invalidResponse):
                message = "Failed to execute gemini --version."
            case .success:
                message = "Gemini CLI not found." // unreachable; guard ensures failure
            }
            return GeminiResumeResult(launched: false, strategy: .none, error: message, command: nil)
        }

        let hasID = (input.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        guard info.supportsResume, hasID else {
            let reason: String
            if !hasID {
                reason = "No session ID available."
            } else {
                reason = "Installed Gemini CLI does not support --resume."
            }
            return GeminiResumeResult(launched: false, strategy: .none, error: reason, command: nil)
        }

        let pkg: GeminiResumeCommandBuilder.CommandPackage
        do {
            pkg = try builder.makeCommand(strategy: .resumeByID(id: input.sessionID!), binaryURL: info.binaryURL, workingDirectory: input.workingDirectory)
        } catch {
            return GeminiResumeResult(launched: false, strategy: .resumeByID, error: error.localizedDescription, command: nil)
        }

        if dryRun {
            return GeminiResumeResult(launched: false, strategy: .resumeByID, error: nil, command: pkg.shellCommand)
        }

        do {
            try launcher.launchInTerminal(pkg)
            return GeminiResumeResult(launched: true, strategy: .resumeByID, error: nil, command: pkg.shellCommand)
        } catch {
            return GeminiResumeResult(launched: false, strategy: .resumeByID, error: error.localizedDescription, command: nil)
        }
    }
}

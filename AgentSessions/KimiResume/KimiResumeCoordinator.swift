import Foundation

@MainActor
final class KimiResumeCoordinator {
    private let env: KimiCLIEnvironmentProviding
    private let builder: KimiResumeCommandBuilder
    private let launcher: KimiTerminalLaunching

    init(env: KimiCLIEnvironmentProviding,
         builder: KimiResumeCommandBuilder,
         launcher: KimiTerminalLaunching) {
        self.env = env
        self.builder = builder
        self.launcher = launcher
    }

    func resumeInTerminal(input: KimiResumeInput,
                          policy: KimiFallbackPolicy = .sessionThenContinue,
                          dryRun: Bool = false) async -> KimiResumeResult {
        // Probing spawns a login shell plus per-candidate --help with no
        // timeout, so it must never run on the MainActor.
        let env = self.env
        let binaryOverride = input.binaryOverride
        let probe = await Task.detached { env.probe(customPath: binaryOverride) }.value
        guard case let .success(info) = probe else {
            let message = probe.failureValue?.localizedDescription ?? "Kimi Code CLI not found."
            return KimiResumeResult(launched: false, strategy: .none, error: message, command: nil)
        }

        let hasID = (input.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        let canSession = info.supportsSession && hasID
        // `--continue` resumes "the previous session for the working
        // directory", so without a known directory it resolves against
        // whatever the terminal happens to open in and silently attaches to an
        // unrelated session while reporting success. Refuse instead.
        let canContinue = info.supportsContinue && input.workingDirectory != nil

        let strategy: KimiResumeCommandBuilder.Strategy
        let used: KimiStrategyUsed

        if canSession {
            strategy = .sessionByID(id: input.sessionID!)
            used = .sessionByID
        } else if policy == .sessionThenContinue, canContinue {
            strategy = .continueMostRecent
            used = .continueMostRecent
        } else {
            let reason: String
            if !hasID && policy == .sessionOnly {
                reason = "No session ID available, and fallback is disabled."
            } else if hasID && !info.supportsSession && policy == .sessionOnly {
                reason = "Installed Kimi Code CLI does not support --session."
            } else if info.supportsContinue && input.workingDirectory == nil {
                reason = "No working directory for this session, so --continue would resume an unrelated one."
            } else {
                reason = "Kimi Code CLI does not advertise required flags (--session/--continue)."
            }
            return KimiResumeResult(launched: false, strategy: .none, error: reason, command: nil)
        }

        let package: KimiResumeCommandBuilder.CommandPackage
        do {
            package = try builder.makeCommand(strategy: strategy,
                                              binaryURL: info.binaryURL,
                                              workingDirectory: input.workingDirectory)
        } catch {
            return KimiResumeResult(launched: false, strategy: used, error: error.localizedDescription, command: nil)
        }

        if dryRun {
            return KimiResumeResult(launched: false, strategy: used, error: nil, command: package.shellCommand)
        }

        do {
            try launcher.launchInTerminal(package)
            return KimiResumeResult(launched: true, strategy: used, error: nil, command: package.shellCommand)
        } catch {
            // No retry here. Nothing `launchInTerminal` throws is
            // command-dependent: Terminal/iTerm fail only when osascript exits
            // non-zero, and the command reaches it as an opaque argv item;
            // Warp fails only on a directory-create or tab-config write.
            // Retrying with a *different* command cannot recover — and if it
            // did succeed it would resume an unrelated session while reporting
            // success.
            return KimiResumeResult(launched: false, strategy: used, error: error.localizedDescription, command: nil)
        }
    }
}

private extension Result where Success == KimiCLIEnvironment.ProbeResult, Failure == KimiCLIEnvironment.ProbeError {
    var failureValue: Failure? { if case let .failure(e) = self { return e } ; return nil }
}

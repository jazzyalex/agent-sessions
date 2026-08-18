import Foundation

protocol KimiCLIEnvironmentProviding {
    func probe(customPath: String?) -> Result<KimiCLIEnvironment.ProbeResult, KimiCLIEnvironment.ProbeError>
}

/// Locates and interrogates the Kimi Code CLI.
///
/// Verified against `kimi --help` at CLI 0.29.1 and re-confirmed unchanged at
/// 0.31.1:
///
///     -S, --session [id]   Resume a session. With ID: resume that session.
///     -c, --continue       Continue the previous session for the working directory.
///
/// Kimi has no `--resume` flag, so — unlike Pi — there is no `supportsResume`
/// capability to probe for.
struct KimiCLIEnvironment: KimiCLIEnvironmentProviding {
    static let binaryName = "kimi"

    struct ProbeResult {
        let versionString: String
        let binaryURL: URL
        let supportsSession: Bool
        let supportsContinue: Bool
    }

    enum ProbeError: Error, LocalizedError {
        case binaryNotFound
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "Kimi Code CLI executable not found."
            case let .commandFailed(stderr):
                return stderr.isEmpty ? "Failed to execute kimi --version." : stderr
            }
        }
    }

    /// Every command this type runs goes through the probe environment, which
    /// owns both the executor and the decision of when to widen PATH.
    private let probeEnv: CLIProbeEnvironment

    init(executor: CommandExecuting = ProcessCommandExecutor()) {
        self.probeEnv = CLIProbeEnvironment(executor: executor, commandName: Self.binaryName)
    }

    func resolveBinary(customPath: String?) -> URL? {
        if let customPath, !customPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = (customPath as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Searched as a whole, never group-by-group with early returns.
        // `bestKimiCLI` falls back to the first executable it saw, so an
        // unverified hit must not end the search: otherwise an unrelated binary
        // of the same name earlier in PATH masks a real CLI installed under one
        // of the later locations. The login shell's answer is considered after
        // this list under the same rule.
        let candidates: [String] = [
            CLIProbeEnvironment.which(Self.binaryName),
            "\(home)/.kimi-code/bin/\(Self.binaryName)",
            "\(home)/.local/bin/\(Self.binaryName)",
            "\(home)/.npm-global/bin/\(Self.binaryName)",
            "/opt/homebrew/bin/\(Self.binaryName)",
            "/usr/local/bin/\(Self.binaryName)"
        ].compactMap { $0 }

        // The login shell is asked last and only if needed: it costs a shell
        // spawn, and every one of the cheap locations above is free to check.
        // Its answer still outranks an unverified hit from that list.
        return bestKimiCLI(from: candidates, deferred: { probeEnv.loginShellExecutablePath() })
    }

    func probe(customPath: String?) -> Result<ProbeResult, ProbeError> {
        guard let binary = resolveBinary(customPath: customPath) else {
            return .failure(.binaryNotFound)
        }

        do {
            let versionRes = try probeEnv.run(binary, "--version")
            let versionString: String
            if versionRes.exitCode == 0 {
                let combined = [versionRes.stdout, versionRes.stderr]
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                versionString = combined.isEmpty ? "unknown" : combined
            } else {
                versionString = "unknown"
            }

            let helpRes = try? probeEnv.run(binary, "--help")
            let helpOut = [helpRes?.stdout, helpRes?.stderr]
                .compactMap { $0 }
                .joined(separator: "\n")

            let supportsSession = CLIProbeEnvironment.helpAdvertises("--session", in: helpOut)
            let supportsContinue = CLIProbeEnvironment.helpAdvertises("--continue", in: helpOut)

            // A probe that never ran is not evidence that Kimi lacks resume
            // flags. A Kimi that actually ran exits 0 for at least one of
            // --version/--help, or prints a flag we recognise; anything else
            // means we learned nothing, and calling that "supports nothing"
            // silently disables every resume action.
            let learnedNothing = !supportsSession && !supportsContinue
            if let reason = CLIProbeEnvironment.probeFailureReason(version: versionRes,
                                                                   help: helpRes,
                                                                   learnedNothing: learnedNothing) {
                return .failure(.commandFailed(reason))
            }

            return .success(
                ProbeResult(
                    versionString: versionString,
                    binaryURL: binary,
                    supportsSession: supportsSession,
                    supportsContinue: supportsContinue
                )
            )
        } catch {
            return .failure(.commandFailed(error.localizedDescription))
        }
    }

    private func bestKimiCLI(from paths: [String], deferred: () -> String?) -> URL? {
        var firstExecutable: URL?
        var seen = Set<String>()

        func consider(_ path: String) -> URL? {
            guard seen.insert(path).inserted else { return nil }
            guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
            let url = URL(fileURLWithPath: path)
            if firstExecutable == nil {
                firstExecutable = url
            }
            return supportsResumeFlags(binary: url) ? url : nil
        }

        for path in paths {
            if let verified = consider(path) { return verified }
        }

        if let late = deferred() {
            if let verified = consider(late) { return verified }
            // Nothing verified itself. What the user's own shell resolves the
            // command to is still the better guess than an unverified hit from
            // our prefix list — which is what searching it first used to give.
            if FileManager.default.isExecutableFile(atPath: late) {
                return URL(fileURLWithPath: late)
            }
        }

        return firstExecutable
    }

    private func supportsResumeFlags(binary: URL) -> Bool {
        let help = try? probeEnv.run(binary, "--help")
        let helpOut = [help?.stdout, help?.stderr]
            .compactMap { $0 }
            .joined(separator: "\n")
        return CLIProbeEnvironment.helpAdvertises("--session", in: helpOut)
            || CLIProbeEnvironment.helpAdvertises("--continue", in: helpOut)
    }
}

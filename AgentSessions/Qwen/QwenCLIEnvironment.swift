import Foundation

protocol QwenCLIEnvironmentProviding {
    func probe(customPath: String?) -> Result<QwenCLIEnvironment.ProbeResult, QwenCLIEnvironment.ProbeError>
}

/// Locates Qwen Code and verifies the resume flags advertised by the installed binary.
/// The installed Qwen Code 0.22.3 `--help` advertises `-r/--resume <id>` and
/// `-c/--continue`, unchanged from the earlier 0.21.13 reading (re-run 2026-08-31); that
/// help surface is still all that has been observed — model execution remains
/// authentication-blocked, so end-to-end resume is untested (matrix pins 0.14.3).
struct QwenCLIEnvironment: QwenCLIEnvironmentProviding {
    static let binaryName = "qwen"

    struct ProbeResult {
        let versionString: String
        let binaryURL: URL
        let supportsResume: Bool
        let supportsContinue: Bool
    }

    enum ProbeError: Error, LocalizedError {
        case binaryNotFound
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound: return "Qwen Code executable not found."
            case .commandFailed(let detail):
                return detail.isEmpty ? "Failed to execute qwen --version." : detail
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
            let url = URL(fileURLWithPath: (customPath as NSString).expandingTildeInPath)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates: [String] = [
            CLIProbeEnvironment.which(Self.binaryName),
            "\(home)/.local/bin/\(Self.binaryName)",
            "\(home)/.npm-global/bin/\(Self.binaryName)",
            "/opt/homebrew/bin/\(Self.binaryName)",
            "/usr/local/bin/\(Self.binaryName)"
        ].compactMap { $0 }

        var firstExecutable: URL?
        var seen: Set<String> = []
        func consider(_ path: String) -> URL? {
            guard seen.insert(path).inserted else { return nil }
            guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
            let url = URL(fileURLWithPath: path)
            if firstExecutable == nil { firstExecutable = url }
            return supportsResumeFlags(binary: url) ? url : nil
        }

        for path in candidates {
            if let verified = consider(path) { return verified }
        }

        // The login shell is asked last and only if needed: it costs a shell
        // spawn, and every location above is free to check. Its answer still
        // outranks an unverified hit from that list.
        if let late = probeEnv.loginShellExecutablePath() {
            if let verified = consider(late) { return verified }
            if FileManager.default.isExecutableFile(atPath: late) {
                return URL(fileURLWithPath: late)
            }
        }
        return firstExecutable
    }

    func probe(customPath: String?) -> Result<ProbeResult, ProbeError> {
        guard let binary = resolveBinary(customPath: customPath) else {
            return .failure(.binaryNotFound)
        }
        do {
            let version = try probeEnv.run(binary, "--version")
            let combined = [version.stdout, version.stderr]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let help = try? probeEnv.run(binary, "--help")
            let helpText = [help?.stdout, help?.stderr].compactMap { $0 }.joined(separator: "\n")

            let supportsResume = CLIProbeEnvironment.helpAdvertises("--resume", in: helpText)
            let supportsContinue = CLIProbeEnvironment.helpAdvertises("--continue", in: helpText)

            // A probe that never ran is not evidence that Qwen lacks resume
            // flags. A Qwen that actually ran exits 0 for at least one of
            // --version/--help, or prints a flag we recognise; anything else
            // means we learned nothing, and calling that "supports nothing"
            // silently disables every resume action.
            let learnedNothing = !supportsResume && !supportsContinue
            if let reason = CLIProbeEnvironment.probeFailureReason(version: version,
                                                                   help: help,
                                                                   learnedNothing: learnedNothing) {
                return .failure(.commandFailed(reason))
            }

            return .success(ProbeResult(
                versionString: version.exitCode == 0 && !combined.isEmpty ? combined : "unknown",
                binaryURL: binary,
                supportsResume: supportsResume,
                supportsContinue: supportsContinue
            ))
        } catch {
            return .failure(.commandFailed(error.localizedDescription))
        }
    }

    private func supportsResumeFlags(binary: URL) -> Bool {
        let help = try? probeEnv.run(binary, "--help")
        let output = [help?.stdout, help?.stderr].compactMap { $0 }.joined(separator: "\n")
        return CLIProbeEnvironment.helpAdvertises("--resume", in: output) || CLIProbeEnvironment.helpAdvertises("--continue", in: output)
    }
}

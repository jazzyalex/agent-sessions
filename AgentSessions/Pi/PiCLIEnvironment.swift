import Foundation

protocol PiCLIEnvironmentProviding {
    func probe(customPath: String?) -> Result<PiCLIEnvironment.ProbeResult, PiCLIEnvironment.ProbeError>
}

struct PiCLIEnvironment: PiCLIEnvironmentProviding {
    struct ProbeResult {
        let versionString: String
        let binaryURL: URL
        let supportsSession: Bool
        let supportsResume: Bool
        let supportsContinue: Bool
    }

    enum ProbeError: Error, LocalizedError {
        case binaryNotFound
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "Pi CLI executable not found."
            case let .commandFailed(stderr):
                return stderr.isEmpty ? "Failed to execute pi --version." : stderr
            }
        }
    }

    /// Every command this type runs goes through the probe environment, which
    /// owns both the executor and the decision of when to widen PATH.
    private let probeEnv: CLIProbeEnvironment

    init(executor: CommandExecuting = ProcessCommandExecutor()) {
        self.probeEnv = CLIProbeEnvironment(executor: executor, commandName: "pi")
    }

    func resolveBinary(customPath: String?) -> URL? {
        if let customPath, !customPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = (customPath as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // One ordered list, searched as a whole, rather than group-by-group
        // early returns. `bestPiCLI` falls back to the first executable it saw,
        // so with the groups separated an unverified hit from the login shell
        // was returned before the later locations were ever examined — meaning
        // an unrelated binary of the same name earlier in PATH would mask a
        // real CLI installed under one of them. `pi` is a short, generic name,
        // so that collision is not hypothetical.
        let candidates: [String] = [
            probeEnv.loginShellExecutablePath(),
            CLIProbeEnvironment.which("pi"),
            "\(home)/.local/bin/pi",
            "\(home)/.npm-global/bin/pi",
            "/opt/homebrew/bin/pi",
            "/usr/local/bin/pi"
        ].compactMap { $0 }

        return bestPiCLI(from: candidates)
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
            let supportsResume = CLIProbeEnvironment.helpAdvertises("--resume", in: helpOut)
            let supportsContinue = CLIProbeEnvironment.helpAdvertises("--continue", in: helpOut)

            // A probe that never ran is not evidence that Pi lacks resume flags.
            // Reporting it as success-with-nothing-supported is what made the
            // resume coordinator answer "Pi CLI does not advertise required
            // flags" for a perfectly capable install. A Pi that actually ran
            // exits 0 for at least one of --version/--help, or prints a flag we
            // recognise; anything else means we learned nothing.
            let learnedNothing = !supportsSession && !supportsResume && !supportsContinue
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
                    supportsResume: supportsResume,
                    supportsContinue: supportsContinue
                )
            )
        } catch {
            return .failure(.commandFailed(error.localizedDescription))
        }
    }

    private func bestPiCLI(from paths: [String]) -> URL? {
        var firstExecutable: URL?
        var seen = Set<String>()

        for path in paths {
            guard seen.insert(path).inserted else { continue }
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            let url = URL(fileURLWithPath: path)
            if firstExecutable == nil {
                firstExecutable = url
            }
            if supportsResumeFlags(binary: url) {
                return url
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
            || CLIProbeEnvironment.helpAdvertises("--resume", in: helpOut)
            || CLIProbeEnvironment.helpAdvertises("--continue", in: helpOut)
    }
}

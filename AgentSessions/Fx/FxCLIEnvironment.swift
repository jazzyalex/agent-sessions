import Foundation

protocol FxCLIEnvironmentProviding {
    func probe(customPath: String?) -> Result<FxCLIEnvironment.ProbeResult, FxCLIEnvironment.ProbeError>
}

/// Locates and interrogates the fx CLI (vercel-labs), a Zig coding agent.
///
/// Verified against `fx --help` at fx 0.0.4:
///
///     -c, --continue          Resume the latest workspace session
///     --resume [last|<id>]    Resume the latest workspace session or an exact ID
///     session resume [last|id]
///
/// The setup script installs to `~/.local/bin/fx`, which Finder-launched apps
/// cannot see through PATH; the candidate list covers it explicitly and asks the
/// login shell last, the same shape every other Node/native CLI here uses.
struct FxCLIEnvironment: FxCLIEnvironmentProviding {
    static let binaryName = "fx"

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
            case .binaryNotFound:
                return "fx CLI executable not found."
            case let .commandFailed(stderr):
                return stderr.isEmpty ? "Failed to execute fx --version." : stderr
            }
        }
    }

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
        let candidates: [String] = [
            CLIProbeEnvironment.which(Self.binaryName),
            "\(home)/.local/bin/\(Self.binaryName)",
            "/opt/homebrew/bin/\(Self.binaryName)",
            "/usr/local/bin/\(Self.binaryName)"
        ].compactMap { $0 }

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
            ?? probeEnv.loginShellExecutablePath().flatMap { path in
                FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
            }
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

            let supportsResume = CLIProbeEnvironment.helpAdvertises("--resume", in: helpOut)
            let supportsContinue = CLIProbeEnvironment.helpAdvertises("--continue", in: helpOut)

            // A probe that never ran is not evidence that fx lacks resume flags.
            // Same rule as Grok: an fx that actually ran exits 0 for at least one
            // of --version/--help or prints a recognised flag; anything else is
            // "nothing learned", which the settings layer discards rather than
            // caching as "supports nothing".
            let learnedNothing = !supportsResume && !supportsContinue
            if let reason = CLIProbeEnvironment.probeFailureReason(version: versionRes,
                                                                   help: helpRes,
                                                                   learnedNothing: learnedNothing) {
                return .failure(.commandFailed(reason))
            }

            return .success(
                ProbeResult(
                    versionString: versionString,
                    binaryURL: binary,
                    supportsResume: supportsResume,
                    supportsContinue: supportsContinue
                )
            )
        } catch {
            return .failure(.commandFailed(error.localizedDescription))
        }
    }
}

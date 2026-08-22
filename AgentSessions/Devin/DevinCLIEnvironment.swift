import Foundation

protocol DevinCLIEnvironmentProviding {
    func probe(customPath: String?) -> Result<DevinCLIEnvironment.ProbeResult, DevinCLIEnvironment.ProbeError>
}

/// Locates and interrogates the Devin CLI.
///
/// Verified against `devin --help` at CLI 3000.3.27 (0becb483):
///
///     -c, --continue       Continue the most recent conversation.
///     -r, --resume [<SESSION_ID>]
///                          Resume a conversation. With an ID, resume that
///                          session; without one, pick interactively.
///
/// Everything here runs through `CLIProbeEnvironment`, the shared helper the
/// other CLI-backed sources use. This file originally hand-rolled its own
/// process handling and reinherited every defect that helper exists to prevent:
/// no PATH widening for a `#!/usr/bin/env node` install, a login shell spawned
/// first and uncached, banners mistaken for binary paths, and — worst — a probe
/// that could not execute the CLI reported as a CLI that supports nothing.
struct DevinCLIEnvironment: DevinCLIEnvironmentProviding {
    static let binaryName = "devin"

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
                return "Devin CLI executable not found."
            case let .commandFailed(detail):
                return detail.isEmpty ? "Failed to execute devin --version." : detail
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
            "\(home)/.local/share/devin/cli/\(Self.binaryName)",
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

            // A probe that never ran is not evidence that Devin lacks resume
            // flags. A Devin that actually ran exits 0 for at least one of
            // --version/--help, or prints a flag we recognise; anything else
            // means we learned nothing, and calling that "supports nothing"
            // silently disables every resume action — the #58 defect.
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
        return CLIProbeEnvironment.helpAdvertises("--resume", in: output)
            || CLIProbeEnvironment.helpAdvertises("--continue", in: output)
    }
}

import Foundation

protocol GrokCLIEnvironmentProviding {
    func probe(customPath: String?) -> Result<GrokCLIEnvironment.ProbeResult, GrokCLIEnvironment.ProbeError>
}

/// Locates and interrogates the Grok CLI.
///
/// Verified against `grok --help` at CLI 1.0.0 (3cd0d0cbcebe):
///
///     -r, --resume [<SESSION_ID_OR_TITLE>]
///                          Resume a session by ID or title, or the most recent
///                          if omitted.
///     -c, --continue       Continue the most recent session for the current
///                          working directory.
///
/// Homebrew also ships an unrelated `grok` *formula* (jordansissel/grok, a regex
/// utility); the Grok CLI itself arrives as the `grok-build` *cask*. Every
/// candidate location is therefore searched as a single ordered list, and a
/// binary whose `--help` advertises the resume flags above always wins over one
/// that does not — so the regex tool cannot mask the real CLI by sitting
/// earlier in PATH. When nothing advertises them the first executable is still
/// returned, so Preferences can report what it actually found.
struct GrokCLIEnvironment: GrokCLIEnvironmentProviding {
    static let binaryName = "grok"

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
                return "Grok CLI executable not found."
            case let .commandFailed(stderr):
                return stderr.isEmpty ? "Failed to execute grok --version." : stderr
            }
        }
    }

    private let executor: CommandExecuting

    init(executor: CommandExecuting = ProcessCommandExecutor()) {
        self.executor = executor
    }

    func resolveBinary(customPath: String?) -> URL? {
        if let customPath, !customPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = (customPath as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // One ordered list, searched as a whole, rather than group-by-group
        // early returns. An unverified hit must not end the search: with the
        // groups separated, a jordansissel `grok` resolved by the login shell
        // was returned as a fallback before `~/.grok/bin` was ever examined,
        // permanently masking a real CLI installed there.
        let candidates: [String] = [
            whichViaLoginShell(Self.binaryName),
            which(Self.binaryName),
            "\(home)/.grok/bin/\(Self.binaryName)",
            "\(home)/.local/bin/\(Self.binaryName)",
            "\(home)/.npm-global/bin/\(Self.binaryName)",
            "/opt/homebrew/bin/\(Self.binaryName)",
            "/usr/local/bin/\(Self.binaryName)"
        ].compactMap { $0 }

        return bestGrokCLI(from: candidates)
    }

    func probe(customPath: String?) -> Result<ProbeResult, ProbeError> {
        guard let binary = resolveBinary(customPath: customPath) else {
            return .failure(.binaryNotFound)
        }

        do {
            let versionRes = try executor.run([binary.path, "--version"], cwd: nil)
            let versionString: String
            if versionRes.exitCode == 0 {
                let combined = [versionRes.stdout, versionRes.stderr]
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                versionString = combined.isEmpty ? "unknown" : combined
            } else {
                versionString = "unknown"
            }

            let helpRes = try? executor.run([binary.path, "--help"], cwd: nil)
            let helpOut = [helpRes?.stdout, helpRes?.stderr]
                .compactMap { $0 }
                .joined(separator: "\n")

            return .success(
                ProbeResult(
                    versionString: versionString,
                    binaryURL: binary,
                    supportsResume: helpContainsFlag("--resume", in: helpOut),
                    supportsContinue: helpContainsFlag("--continue", in: helpOut)
                )
            )
        } catch {
            return .failure(.commandFailed(error.localizedDescription))
        }
    }

    private func which(_ command: String) -> String? {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for component in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(component)).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate.path }
        }
        return nil
    }

    private func whichViaLoginShell(_ command: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        do {
            let result = try executor.run([shell, "-lic", "command -v \(command) || true"], cwd: nil)
            let res = [result.stdout, result.stderr].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !res.isEmpty, res != command else { return nil }
            return res.split(whereSeparator: { $0.isNewline }).first.map(String.init)
        } catch {
            return nil
        }
    }

    private func bestGrokCLI(from paths: [String]) -> URL? {
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
        let help = try? executor.run([binary.path, "--help"], cwd: nil)
        let helpOut = [help?.stdout, help?.stderr]
            .compactMap { $0 }
            .joined(separator: "\n")
        return helpContainsFlag("--resume", in: helpOut)
            || helpContainsFlag("--continue", in: helpOut)
    }

    private func helpContainsFlag(_ flag: String, in help: String) -> Bool {
        help.split { character in
            character.isWhitespace || ",=[](){}<>:;".contains(character)
        }
        .contains { $0 == flag }
    }
}

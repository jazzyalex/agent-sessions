import Foundation

protocol ClineCLIEnvironmentProviding {
    func probe(customPath: String?) -> Result<ClineCLIEnvironment.ProbeResult, ClineCLIEnvironment.ProbeError>
}

/// Locates and interrogates the Cline CLI.
///
/// The CLI exposes `cline --version` and `cline --help`; resume is not claimed,
/// so the probe only resolves the binary and its version string. Availability
/// itself is filesystem-first (the shared `~/.cline/data/sessions` root covers
/// both CLI and Desktop sessions) with the binary as fallback.
struct ClineCLIEnvironment: ClineCLIEnvironmentProviding {
    static let binaryName = "cline"

    struct ProbeResult {
        let versionString: String
        let binaryURL: URL
    }

    enum ProbeError: Error, LocalizedError {
        case binaryNotFound
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "Cline CLI executable not found."
            case let .commandFailed(stderr):
                return stderr.isEmpty ? "Failed to execute cline --version." : stderr
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
            let combined = [versionRes.stdout, versionRes.stderr]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard versionRes.exitCode == 0 else {
                return .failure(.commandFailed(combined))
            }
            let versionString = combined.isEmpty ? "unknown" : combined
            return .success(ProbeResult(versionString: versionString, binaryURL: binary))
        } catch {
            return .failure(.commandFailed(error.localizedDescription))
        }
    }
}

import Foundation

/// Lightweight CLI probe for the `droid` command.
/// Detects binary location and version string.
struct DroidCLIEnvironment {
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
                return "Droid CLI executable not found."
            case let .commandFailed(stderr):
                return stderr.isEmpty ? "Failed to execute droid --version." : stderr
            }
        }
    }

    func resolveBinary(customPath: String?) -> URL? {
        if let customPath, !customPath.trimmingCharacters(in: .whitespaces).isEmpty {
            let expanded = (customPath as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }

        if let fromLogin = whichViaLoginShell("droid"), FileManager.default.isExecutableFile(atPath: fromLogin) {
            return URL(fileURLWithPath: fromLogin)
        }

        if let path = which("droid") { return URL(fileURLWithPath: path) }

        let candidates = [
            "/opt/homebrew/bin/droid",
            "/usr/local/bin/droid"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        return nil
    }

    func probe(customPath: String?) -> Result<ProbeResult, ProbeError> {
        guard let binary = resolveBinary(customPath: customPath) else {
            return .failure(.binaryNotFound)
        }

        let shell = defaultShell()
        let versionCmd = "\(escapeForShell(binary.path)) --version"
        let vres = runAndCapture([shell, "-lic", versionCmd])
        if vres.status != 0 {
            // Some CLIs use `version` subcommand instead.
            let fallbackCmd = "\(escapeForShell(binary.path)) version"
            let fres = runAndCapture([shell, "-lic", fallbackCmd])
            guard fres.status == 0 else {
                return .failure(.commandFailed((vres.err ?? "") + (fres.err ?? "")))
            }
            let combined = ((fres.out ?? "") + (fres.err ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
            return .success(ProbeResult(versionString: combined.isEmpty ? "unknown" : combined, binaryURL: binary))
        }

        let combined = ((vres.out ?? "") + (vres.err ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(ProbeResult(versionString: combined.isEmpty ? "unknown" : combined, binaryURL: binary))
    }

    // MARK: - Helpers

    private func which(_ command: String) -> String? {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for component in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(component)).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate.path }
        }
        return nil
    }

    private func whichViaLoginShell(_ command: String) -> String? {
        let shell = defaultShell()
        let res = runAndCapture([shell, "-lic", "command -v \(command) || true"]).out?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !res.isEmpty else { return nil }
        if res == command { return nil }
        return res.split(whereSeparator: { $0.isNewline }).first.map(String.init)
    }

    private func defaultShell() -> String { ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh" }

    private func runAndCapture(_ argv: [String]) -> (status: Int32, out: String?, err: String?) {
        guard let first = argv.first else { return (127, nil, "no command") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: first)
        process.arguments = Array(argv.dropFirst())
        process.environment = ProcessInfo.processInfo.environment
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do { try process.run() } catch {
            return (127, nil, error.localizedDescription)
        }
        process.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        return (process.terminationStatus, out, err)
    }

    private func escapeForShell(_ s: String) -> String {
        if s.isEmpty { return "''" }
        if !s.contains("'") { return "'\(s)'" }
        return "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

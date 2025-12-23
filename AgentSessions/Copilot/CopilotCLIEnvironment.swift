import Foundation

/// Lightweight CLI probe for the `copilot` command.
/// Detects binary location and version string.
struct CopilotCLIEnvironment {
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
                return "Copilot CLI executable not found."
            case let .commandFailed(stderr):
                return stderr.isEmpty ? "Failed to execute copilot --version." : stderr
            }
        }
    }

    func resolveBinary(customPath: String?) -> URL? {
        // 1) Respect explicit override if it points to an executable
        if let customPath, !customPath.trimmingCharacters(in: .whitespaces).isEmpty {
            let expanded = (customPath as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }

        // 2) Ask the user's login+interactive shell (mirrors Terminal PATH)
        if let fromLogin = whichViaLoginShell("copilot"), FileManager.default.isExecutableFile(atPath: fromLogin) {
            return URL(fileURLWithPath: fromLogin)
        }

        // 3) Try our current process PATH
        if let path = which("copilot") { return URL(fileURLWithPath: path) }

        // 4) Common install locations (Homebrew)
        var candidates: [String] = []
        if let brewPrefix = runAndCapture(["/usr/bin/env", "brew", "--prefix"]).out?.trimmingCharacters(in: .whitespacesAndNewlines), !brewPrefix.isEmpty {
            candidates.append("\(brewPrefix)/bin/copilot")
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/copilot",
            "/usr/local/bin/copilot"
        ])

        for path in Set(candidates) {
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }

        return nil
    }

    /// Returns version string by inspecting `--version`.
    func probe(customPath: String?) -> Result<ProbeResult, ProbeError> {
        guard let binary = resolveBinary(customPath: customPath) else {
            return .failure(.binaryNotFound)
        }

        // Run via the user's login shell so PATH and Node shebang resolution match Terminal.
        let shell = defaultShell()
        let versionCmd = "\(escapeForShell(binary.path)) --version"
        let vres = runAndCapture([shell, "-lic", versionCmd])
        guard vres.status == 0 else {
            return .failure(.commandFailed(vres.err ?? "Failed to execute copilot --version."))
        }

        let combined = ((vres.out ?? "") + (vres.err ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
        let versionStr = combined.isEmpty ? "unknown" : combined
        return .success(ProbeResult(versionString: versionStr, binaryURL: binary))
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


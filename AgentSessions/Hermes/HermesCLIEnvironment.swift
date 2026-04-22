import Foundation

struct HermesCLIEnvironment {
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
                return "Hermes CLI executable not found."
            case .commandFailed(let stderr):
                return stderr.isEmpty ? "Failed to execute hermes --version." : stderr
            }
        }
    }

    func resolveBinary(customPath: String?) -> URL? {
        if let customPath, !customPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = (customPath as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) {
                return URL(fileURLWithPath: expanded)
            }
        }

        if let fromLogin = whichViaLoginShell("hermes"), FileManager.default.isExecutableFile(atPath: fromLogin) {
            return URL(fileURLWithPath: fromLogin)
        }
        if let fromPath = which("hermes") {
            return URL(fileURLWithPath: fromPath)
        }

        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/hermes").path,
            "/opt/homebrew/bin/hermes",
            "/usr/local/bin/hermes"
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
        guard vres.status == 0 else {
            return .failure(.commandFailed(vres.err ?? ""))
        }

        let helpCmd = "\(escapeForShell(binary.path)) --help"
        let hres = runAndCapture([shell, "-lic", helpCmd])
        let helpOut = (hres.out ?? "") + (hres.err ?? "")
        let versionString = ((vres.out ?? "") + (vres.err ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(ProbeResult(versionString: versionString.isEmpty ? "unknown" : versionString,
                                    binaryURL: binary,
                                    supportsResume: helpOut.contains("--resume"),
                                    supportsContinue: helpOut.contains("--continue")))
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
        let res = runAndCapture([defaultShell(), "-lic", "command -v \(command) || true"]).out?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !res.isEmpty, res != command else { return nil }
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
        process.waitForExit()
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

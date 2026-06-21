import Foundation

struct GeminiCLIEnvironment {
    struct ProbeResult {
        let versionString: String
        let binaryURL: URL
        let supportsResume: Bool
    }

    enum ProbeError: Error {
        case notFound
        case invalidResponse
    }

    private let executor: CommandExecuting

    init(executor: CommandExecuting = ProcessCommandExecutor()) {
        self.executor = executor
    }

    func probe(customPath: String?) -> Result<ProbeResult, ProbeError> {
        let resolved = resolveBinary(customPath: customPath)
        if let url = resolved {
            do {
                let result = try executor.run([url.path, "--version"], cwd: nil)
                if result.exitCode == 0 {
                    let rawStdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    let rawStderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    let version = rawStdout.isEmpty ? rawStderr : rawStdout
                    let supportsResume = probeHelpForResume(binaryPath: url.path)
                    guard supportsResume else { return .failure(.invalidResponse) }
                    return .success(ProbeResult(versionString: version, binaryURL: url, supportsResume: supportsResume))
                }
            } catch {
                return .failure(.notFound)
            }
        }

        let command = customPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? customPath!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "agy"

        let shell = defaultShell()
        let versionCmd = "\(escapeForShell(command)) --version"
        let vres = runAndCapture([shell, "-lic", versionCmd])
        guard vres.status == 0 else { return .failure(.notFound) }

        let combined = ((vres.out ?? "") + (vres.err ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combined.isEmpty else { return .failure(.invalidResponse) }

        // Try to recover a path for UI affordances; if we already resolved a URL
        // use that; otherwise ask the shell for the binary location.
        let pathString: String
        if let url = resolved {
            pathString = url.path
        } else {
            let pres = runAndCapture([shell, "-lic", "command -v \(escapeForShell(command)) || which \(escapeForShell(command)) || echo \(escapeForShell(command))"])
            pathString = (pres.out ?? "")
                .split(whereSeparator: { $0.isNewline })
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? command
        }

        let url = URL(fileURLWithPath: pathString)
        let supportsResume = probeHelpForResume(binaryPath: pathString)
        guard supportsResume else { return .failure(.invalidResponse) }
        return .success(ProbeResult(versionString: combined, binaryURL: url, supportsResume: supportsResume))
    }

    private func probeHelpForResume(binaryPath: String) -> Bool {
        let shell = defaultShell()
        let helpCmd = "\(escapeForShell(binaryPath)) --help"
        let hres = runAndCapture([shell, "-lic", helpCmd])
        let helpOut = (hres.out ?? "") + (hres.err ?? "")
        return helpOut.contains("--conversation") && helpOut.contains("--continue") && helpOut.contains("--print")
    }

    // Resolve the Antigravity CLI binary. The desktop app also installs an `agy`
    // launcher; accept only binaries whose help output exposes terminal CLI flags.
    private func resolveBinary(customPath: String?) -> URL? {
        if let customPath, !customPath.trimmingCharacters(in: .whitespaces).isEmpty {
            let expanded = (customPath as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded), probeHelpForResume(binaryPath: expanded) {
                return URL(fileURLWithPath: expanded)
            }
        }

        let local = (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/agy")
        if FileManager.default.isExecutableFile(atPath: local), probeHelpForResume(binaryPath: local) {
            return URL(fileURLWithPath: local)
        }

        if let path = which("agy"), probeHelpForResume(binaryPath: path) {
            return URL(fileURLWithPath: path)
        }

        if let fromLogin = whichViaLoginShell("agy"), FileManager.default.isExecutableFile(atPath: fromLogin), probeHelpForResume(binaryPath: fromLogin) {
            return URL(fileURLWithPath: fromLogin)
        }

        return nil
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
        let shell = defaultShell()
        let res = runAndCapture([shell, "-lic", "command -v \(command) || true"]).out?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !res.isEmpty else { return nil }
        if res == command { return nil }
        return res.split(whereSeparator: { $0.isNewline }).first.map(String.init)
    }

    private func defaultShell() -> String { ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh" }

    private func escapeForShell(_ s: String) -> String {
        if s.isEmpty { return "''" }
        if !s.contains("'") { return "'\(s)'" }
        return "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

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
}

import Foundation

struct GeminiCLIEnvironment {
    struct ProbeResult {
        let versionString: String
        let binaryURL: URL
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
        // 1) Prefer a concrete binary path when we can resolve one.
        let resolved = resolveBinary(customPath: customPath)
        if let url = resolved {
            do {
                let result = try executor.run([url.path, "--version"], cwd: nil)
                if result.exitCode == 0 {
                    let rawStdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    let rawStderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Some npm CLIs emit version to stderr; fall back if stdout is empty.
                    let version = rawStdout.isEmpty ? rawStderr : rawStdout
                    return .success(ProbeResult(versionString: version, binaryURL: url))
                }
                // Non‑zero exit: fall through to shell-based probe instead of failing early.
            } catch {
                // Fall through to shell-based probe so we still respect aliases or
                // login-shell PATH even if direct exec fails.
            }
        }

        // 2) Fallback: use the user's login shell to run the command.
        let command: String
        if let url = resolved {
            command = url.path
        } else if let custom = customPath?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            command = custom
        } else {
            command = "gemini"
        }

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
            let pres = runAndCapture([shell, "-lic", "command -v \(command) || which \(command) || echo \(command)"])
            pathString = (pres.out ?? "")
                .split(whereSeparator: { $0.isNewline })
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? command
        }

        let url = URL(fileURLWithPath: pathString)
        return .success(ProbeResult(versionString: combined, binaryURL: url))
    }

    // Resolve the Gemini binary using custom override, login shell PATH, common install locations, and local project bin.
    private func resolveBinary(customPath: String?) -> URL? {
        // 1) Explicit override
        if let customPath, !customPath.trimmingCharacters(in: .whitespaces).isEmpty {
            let expanded = (customPath as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) { return URL(fileURLWithPath: expanded) }
        }

        // 2) Login shell PATH (matches Terminal)
        if let fromLogin = whichViaLoginShell("gemini"), FileManager.default.isExecutableFile(atPath: fromLogin) {
            return URL(fileURLWithPath: fromLogin)
        }

        // 3) Current process PATH
        if let path = which("gemini") { return URL(fileURLWithPath: path) }

        // 4) Common install locations (Homebrew / npm global)
        var candidates: [String] = []
        if let brewPrefix = runAndCapture(["/usr/bin/env", "brew", "--prefix"]).out?.trimmingCharacters(in: .whitespacesAndNewlines), !brewPrefix.isEmpty {
            candidates.append("\(brewPrefix)/bin/gemini")
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/gemini",
            "/usr/local/bin/gemini"
        ])
        if let npmPrefix = runAndCapture(["/usr/bin/env", "npm", "prefix", "-g"]).out?.trimmingCharacters(in: .whitespacesAndNewlines), !npmPrefix.isEmpty {
            candidates.append("\(npmPrefix)/bin/gemini")
        }
        candidates.append((NSHomeDirectory() as NSString).appendingPathComponent(".npm-global/bin/gemini"))
        candidates.append((NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/gemini"))

        for path in Set(candidates) {
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }

        // 5) Project-local .bin
        let local = (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent("node_modules/.bin/gemini")
        if FileManager.default.isExecutableFile(atPath: local) { return URL(fileURLWithPath: local) }

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
        process.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        return (process.terminationStatus, out, err)
    }
}

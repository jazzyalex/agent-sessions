import Foundation

/// Utility for executing git commands via shell
actor GitCommandRunner {
    /// Execute a git command safely using Process (no shell), returning trimmed stdout on success.
    func runGit(_ args: [String], in workingDirectory: String, timeout: TimeInterval = 5.0) async -> String? {
        // Basic safety: require directory to exist within the user's home folder.
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: workingDirectory, isDirectory: &isDir), isDir.boolValue else { return nil }
        if let home = fm.homeDirectoryForCurrentUser.path as String?, !workingDirectory.hasPrefix(home) {
            // Avoid executing in unexpected system locations
            return nil
        }

        let process = Process()
        let pipe = Pipe()
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        // Use /usr/bin/env to resolve git in PATH
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.standardOutput = pipe
        process.standardError = Pipe() // discard or capture separately if needed

        do {
            try process.run()

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if process.isRunning {
                process.terminate()
                return nil
            }
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (output?.isEmpty == true) ? nil : output
        } catch {
            return nil
        }
    }

    /// Check if a directory is a git repository (quick test)
    func isGitRepository(_ path: String) async -> Bool {
        return await runGit(["rev-parse", "--git-dir"], in: path) != nil
    }
}

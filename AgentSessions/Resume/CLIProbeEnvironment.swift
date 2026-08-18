import Foundation

/// Environment for probing an agent CLI, and login-shell discovery of where it lives.
///
/// A Finder-launched app inherits `PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin`
/// — no Homebrew, no npm prefix, no Node version-manager shim. CLIs shipped as Node
/// scripts start with `#!/usr/bin/env node`, so running one under that PATH dies with
/// `env: node: No such file or directory` before the CLI itself ever starts. Probing
/// a CLI therefore has to hand the child a PATH the user would actually have, which
/// only their login shell knows.
///
/// The shell is asked exactly once per instance and both answers come back from the
/// same invocation, delimited by markers: login shells print banners, MOTDs and
/// version-manager chatter, and without delimiters a banner line can be mistaken for
/// the resolved binary path.
final class CLIProbeEnvironment {
    struct Marker {
        let begin: String
        let end: String
    }

    static let pathMarker = Marker(begin: "__AS_PROBE_PATH_BEGIN__", end: "__AS_PROBE_PATH_END__")
    static let whichMarker = Marker(begin: "__AS_PROBE_WHICH_BEGIN__", end: "__AS_PROBE_WHICH_END__")

    private let executor: CommandExecuting
    private let commandName: String
    private var cached: (path: String, executablePath: String?)?

    init(executor: CommandExecuting, commandName: String) {
        self.executor = executor
        self.commandName = commandName
    }

    /// Where the login shell says the CLI lives, or nil if it does not know.
    func loginShellExecutablePath() -> String? {
        discover().executablePath
    }

    /// The environment probe commands should run under: the inherited environment
    /// with PATH widened to what the login shell and the usual install prefixes offer.
    func probeEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = discover().path
        return env
    }

    private func discover() -> (path: String, executablePath: String?) {
        if let cached { return cached }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let script = """
        printf '%s%s%s\\n' '\(Self.pathMarker.begin)' "$PATH" '\(Self.pathMarker.end)'
        printf '%s%s%s\\n' '\(Self.whichMarker.begin)' "$(command -v '\(commandName)' || true)" '\(Self.whichMarker.end)'
        """
        // stdout only: the markers survive stderr chatter, but merging the streams
        // would let a banner printed between the two printfs land inside a field.
        let stdout = (try? executor.run([shell, "-lic", script], cwd: nil))?.stdout ?? ""

        let loginPath = Self.field(Self.pathMarker, in: stdout)
        let which = Self.field(Self.whichMarker, in: stdout).flatMap { candidate -> String? in
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != commandName else { return nil }
            return trimmed
        }

        let resolved = (path: Self.mergedPath(loginPath: loginPath), executablePath: which)
        cached = resolved
        return resolved
    }

    /// Login-shell PATH first — the user's own ordering is the one that works —
    /// then our inherited PATH, then the prefixes a Node or Homebrew install uses.
    private static func mergedPath(loginPath: String?) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Fixed prefixes only. The Node version managers people actually use put
        // their shims behind a version or a per-shell directory — nvm at
        // `~/.nvm/versions/node/<version>/bin`, fnm under a multishell path
        // keyed to the running shell — so there is nothing static to add for
        // them. The login-shell PATH above is what covers those installs, and
        // this list is the floor for when the shell could not be asked.
        let fallbacks = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.volta/bin",
            "\(home)/.bun/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]

        let sources = [loginPath, ProcessInfo.processInfo.environment["PATH"]]
            .compactMap { $0 }
            .flatMap { $0.split(separator: ":").map(String.init) }

        var seen = Set<String>()
        return (sources + fallbacks)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
    }

    private static func field(_ marker: Marker, in output: String) -> String? {
        guard let start = output.range(of: marker.begin),
              let end = output.range(of: marker.end, range: start.upperBound..<output.endIndex) else {
            return nil
        }
        let value = String(output[start.upperBound..<end.lowerBound])
        return value.isEmpty ? nil : value
    }
}

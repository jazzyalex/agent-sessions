import Foundation

/// Deterministic, subprocess-free check for whether a provider's CLI binary
/// exists on disk.
///
/// Used to gate the alarming `.cliNotInstalled` verdict. The previous approach
/// (`ClaudeCLIEnvironment.resolveBinary`) spawns a login shell + `brew --prefix`
/// + `npm prefix -g` with no timeout, so a transient flake (cold shell right
/// after wake-from-sleep, fork failure under memory pressure) could return
/// "not found" for a CLI that is actually installed — firing a false
/// "install the CLI" banner/notification with no debounce. A plain
/// `FileManager` existence check over the known install locations never blocks
/// and never flakes, so it is safe to drive an immediate alarm.
///
/// Note: a false negative here (binary installed at some exotic path not in the
/// candidate list) is harmless, because `.cliNotInstalled` only fires when there
/// is ALSO no token; a signed-in user always has a token, so the gate is never
/// reached for them regardless of the candidate list.
enum CLIBinaryPresence {
    /// Pure core — testable with an injected existence check.
    static func isPresent(overridePath: String?,
                          candidates: [String],
                          fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        if let override = overridePath, !override.isEmpty, fileExists(override) { return true }
        return candidates.contains(where: fileExists)
    }

    static func claudeCandidates(home: String = NSHomeDirectory()) -> [String] {
        [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/node_modules/.bin/claude",
        ]
    }

    static func codexCandidates(home: String = NSHomeDirectory()) -> [String] {
        [
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "\(home)/node_modules/.bin/codex",
        ]
    }

    static func claudeInstalled(overridePath: String?) -> Bool {
        isPresent(overridePath: overridePath, candidates: claudeCandidates())
    }

    static func codexInstalled(overridePath: String?) -> Bool {
        isPresent(overridePath: overridePath, candidates: codexCandidates())
    }
}

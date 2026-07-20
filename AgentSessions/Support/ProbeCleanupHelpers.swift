import Darwin
import Foundation

/// Normalizes a file-system path: expands tilde and standardizes separators/symlinks.
func normalizeProbePath(_ path: String) -> String {
    ((path as NSString).expandingTildeInPath as NSString).standardizingPath
}

/// Kills socketless probe tmux servers found in a `ps` snapshot.
///
/// When a prior partial cleanup deletes the tmux socket file before sending
/// kill-server, the tmux server process keeps running but is unreachable via
/// tmux commands. SIGTERM is not useful here because there is no socket through
/// which tmux can receive it; SIGKILL is the only remaining option.
///
/// - Parameters:
///   - labelPrefix: Only processes whose `-L <label>` starts with this prefix are targeted.
///   - psOutput:    Raw output from `ps -Ao pid,command` (or equivalent). Reuse an
///                  already-captured snapshot to avoid an extra `ps` invocation.
///   - socketExists: Injectable socket-presence check (defaults to the real filesystem check).
///   - killAction:   Injectable kill action (defaults to `SIGKILL` via `Darwin.kill`).
func terminateSocketlessProbeServers(labelPrefix: String,
                                     psOutput: String,
                                     socketExists: ((String) -> Bool)? = nil,
                                     killAction: ((pid_t) -> Void)? = nil) {
    guard !psOutput.isEmpty else { return }
    let uid = getuid()
    let socketDirs = ["/private/tmp/tmux-\(uid)", "/tmp/tmux-\(uid)"]
    let socketCheck = socketExists ?? { label in
        socketDirs.contains { FileManager.default.fileExists(atPath: "\($0)/\(label)") }
    }
    let kill = killAction ?? { pid in _ = Darwin.kill(pid, SIGKILL) }
    for line in psOutput.split(separator: "\n") {
        let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard parts.count == 2, let tmuxPID = Int32(parts[0]) else { continue }
        let command = String(parts[1])
        guard command.contains("tmux"), command.contains(labelPrefix) else { continue }
        // Extract label from the -L <label> argument.
        guard let lRange = command.range(of: "-L ") else { continue }
        let afterL = command[lRange.upperBound...]
        let labelEnd = afterL.firstIndex(where: { $0.isWhitespace }) ?? afterL.endIndex
        let label = String(afterL[..<labelEnd])
        guard label.hasPrefix(labelPrefix) else { continue }
        // Only kill if the socket file is gone.
        if !socketCheck(label) {
            kill(pid_t(tmuxPID))
        }
    }
}

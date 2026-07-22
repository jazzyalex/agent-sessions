import Foundation

/// Synthesizes live presences for Claude **Desktop** chats.
///
/// Desktop chats are written by the Claude GUI app: no tty, no terminal process, no iTerm
/// session — so none of the existing discovery probes (registry, ps/lsof, iTerm) can see
/// them. Their transcripts in `~/.claude/projects/<project>/<session>.jsonl` are the only
/// footprint. This scanner turns recently-written transcripts into `CodexActivePresence`
/// values (source `.claude`, `kind == "desktop"`) so Desktop chats flow through the same
/// classify → publish → join pipeline as every other live session: the sessions-list dot,
/// the Cockpit HUD, and the Stream Deck bridge all pick them up with no special-casing.
enum ClaudeDesktopPresenceScanner {
    /// Marker used on synthesized presences; the live-state classifier keys on this.
    static let desktopKind = "desktop"
    /// Transcripts untouched for longer than this are not "live" — no presence is emitted.
    static let liveWindow: TimeInterval = 30 * 60
    /// Upper bound on emitted presences per cycle (most-recent wins).
    static let maxPresences = 32

    static func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Scan the Claude session roots for recently-modified top-level transcripts that no
    /// existing presence already claims and that were written by the Desktop app (see
    /// `isClaudeDesktopTranscript`), and synthesize Desktop presences for them.
    ///
    /// The Claude root is `~/.claude` (per `ClaudeSessionDiscovery.sessionsRoot()`); the
    /// transcripts live at `projects/<project>/<session>.jsonl`, so the walk targets the
    /// `projects` subtree. Subagent transcripts live deeper (`<project>/<session>/subagents/…`)
    /// and are deliberately skipped by not descending past the project level.
    static func scan(roots: [String],
                     now: Date,
                     excludingNormalizedLogPaths claimed: Set<String>) -> [CodexActivePresence] {
        let fm = FileManager.default
        var candidates: [(path: String, mtime: Date)] = []

        for root in roots {
            let rootURL = URL(fileURLWithPath: root, isDirectory: true)
            let projectsURL = rootURL.appendingPathComponent("projects", isDirectory: true)
            var isDir: ObjCBool = false
            let scanBase = (fm.fileExists(atPath: projectsURL.path, isDirectory: &isDir) && isDir.boolValue)
                ? projectsURL : rootURL
            let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
            guard let enumerator = fm.enumerator(at: scanBase,
                                                 includingPropertiesForKeys: keys,
                                                 options: [.skipsHiddenFiles]) else { continue }
            let baseDepth = scanBase.standardizedFileURL.pathComponents.count
            for case let url as URL in enumerator {
                let depth = url.standardizedFileURL.pathComponents.count - baseDepth
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true {
                    // Descend into project dirs (depth 1) only — session subdirs hold subagents.
                    if depth >= 2 { enumerator.skipDescendants() }
                    continue
                }
                guard depth <= 2, url.pathExtension == "jsonl" else { continue }
                guard let mtime = values?.contentModificationDate,
                      now.timeIntervalSince(mtime) <= liveWindow else { continue }
                guard !claimed.contains(normalizePath(url.path)) else { continue }
                candidates.append((url.path, mtime))
            }
        }

        return candidates
            .sorted { $0.mtime > $1.mtime }
            .filter { isClaudeDesktopTranscript(logPath: $0.path) }
            .prefix(maxPresences)
            .map { candidate in
                var presence = CodexActivePresence()
                presence.source = .claude
                presence.kind = desktopKind
                presence.schemaVersion = 1
                presence.publisher = "claude-desktop-scan"
                presence.sessionId = URL(fileURLWithPath: candidate.path)
                    .deletingPathExtension().lastPathComponent
                presence.sessionLogPath = candidate.path
                presence.sourceFilePath = candidate.path
                presence.lastSeenAt = now
                return presence
            }
    }

    /// True when the transcript was written by the Claude **Desktop** app, identified by the
    /// `entrypoint == "claude-desktop"` marker its records carry. Claude Code CLI transcripts
    /// live in the same `projects` tree but carry `entrypoint == "cli"` and already have a
    /// terminal/iTerm footprint the other probes claim; requiring the Desktop marker keeps an
    /// exited CLI session from lingering as a phantom live Desktop presence for the window.
    /// Reads only the head (the marker rides on the first user/assistant record), bounded to
    /// the already-window-filtered candidates so it stays cheap.
    private static func isClaudeDesktopTranscript(logPath: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: logPath) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 96 * 1024)) ?? Data()
        guard !head.isEmpty else { return false }
        for line in String(decoding: head, as: UTF8.self).split(separator: "\n").prefix(200) {
            guard line.first == "{",
                  let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let entrypoint = object["entrypoint"] as? String else { continue }
            return entrypoint == "claude-desktop"
        }
        return false
    }

    /// Whose turn is it? Reads only the transcript tail. `true` only when the newest
    /// assistant message handed the turn back to the user — a `stop_reason` of `end_turn`
    /// or `stop_sequence`, matching `ClaudeRunwayRecentSessionScanner.isIdleMarker`.
    ///
    /// Everything else means still working: a `tool_use` stop (a tool is running), a
    /// non-terminal stop (`max_tokens`, `null`, `refusal`), or a trailing `user` entry
    /// (tool results ride in user entries). Returns nil only when the tail can't be read.
    static func lastTurnIsEndOfAssistantTurn(logPath: String?) -> Bool? {
        guard let logPath, let handle = FileHandle(forReadingAtPath: logPath) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let tail: UInt64 = 16384
        try? handle.seek(toOffset: end > tail ? end - tail : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
            guard line.first == "{",
                  let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            if type == "user" { return false }        // tool result / user prompt => mid-turn
            guard type == "assistant" else { continue }
            guard let stop = (object["message"] as? [String: Any])?["stop_reason"] as? String else {
                return false                            // no terminal stop yet => still working
            }
            return stop == "end_turn" || stop == "stop_sequence"
        }
        return nil
    }
}

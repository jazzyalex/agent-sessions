import Foundation

/// Discovers currently-active Claude sessions by scanning `~/.claude/projects`,
/// mirroring `CodexRunwayRecentSessionScanner` for the Codex side. This lets the
/// runway surface sessions that the HUD presence tracker may not have resolved
/// into rows yet.
///
/// Claude keeps one JSONL file per session and nests subagents in-file
/// (`isSidechain`), so there is no cross-file parent/child merging like Codex.
enum ClaudeRunwayRecentSessionScanner {
    static let maximumFileAge: TimeInterval = 30 * 60
    /// How long a session row stays on screen after its last logged line.
    /// Claude only writes a line at the end of each turn, so gaps during tool
    /// calls / thinking routinely exceed 30s — a short window here makes rows
    /// flicker in and out. Kept wide (matching the Codex scanner) for stable
    /// row presence; burn-rate freshness is handled separately by the token
    /// parser's much shorter window.
    static let maximumActiveSampleAge: TimeInterval = 75
    /// Presence window for a session that has handed back to the user — its last
    /// assistant turn ended with `end_turn`/`stop_sequence`. Such a session is
    /// idle (not burning, and won't be until the user acts), so it leaves the
    /// runway well before a working session would. Kept above the parser's burn
    /// window so the brief present-but-not-burning tail can render as a calm "—"
    /// (Track 2) instead of a misleading spinner; until then that tail is short.
    static let idleSessionGrace: TimeInterval = 45
    static let maximumFiles = 12
    static func defaultRoot() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    static func identities(root: URL? = nil,
                           now: Date = Date(),
                           fileManager: FileManager = .default) -> [RunwaySessionIdentity] {
        let rootURL = root ?? defaultRoot()
        let cutoff = now.addingTimeInterval(-maximumFileAge)
        var candidates: [(url: URL, modifiedAt: Date, signature: RunwayFileSignature)] = []

        guard fileManager.fileExists(atPath: rootURL.path),
              let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else {
            return []
        }

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true,
                  let modifiedAt = values?.contentModificationDate,
                  modifiedAt >= cutoff else {
                continue
            }
            let signature = RunwayFileSignature(mtime: modifiedAt, size: UInt64(values?.fileSize ?? 0))
            candidates.append((url, modifiedAt, signature))
        }

        // Unchanged files (same mtime+size) reuse their head/tail parse; only the
        // now-dependent active window is recomputed below. Prune to the current
        // in-window set so the cache tracks the recent-file set, not history.
        fileCache.retain(paths: Set(candidates.map { $0.url.path }))

        var byID: [String: (displayName: String, logPaths: [String], hasPrimaryName: Bool, isIdle: Bool)] = [:]
        var order: [String] = []
        // Scan recent files, then group by session id so a session's subagent
        // transcripts (which live in <sessionId>/subagents/ and carry the parent
        // session id) fold into the parent: their burn is counted via the extra
        // log path, but the parent's name and a single row win. maximumFiles is
        // applied to distinct sessions, not raw files, so subagents can't crowd
        // out other sessions.
        for entry in candidates.sorted(by: { $0.modifiedAt > $1.modifiedAt }) {
            guard let candidate = candidate(for: entry.url, now: now, signature: entry.signature) else { continue }
            if var existing = byID[candidate.id] {
                existing.logPaths.append(candidate.logPath)
                // A non-subagent (parent) transcript's name beats a subagent's
                // internal task prompt.
                if !candidate.isSubagent, !existing.hasPrimaryName {
                    existing.displayName = candidate.displayName
                    existing.hasPrimaryName = true
                }
                // Idle only if every contributing file is idle (a working
                // subagent keeps the session working).
                existing.isIdle = existing.isIdle && candidate.isIdle
                byID[candidate.id] = existing
            } else {
                guard order.count < maximumFiles else { continue }
                order.append(candidate.id)
                byID[candidate.id] = (candidate.displayName, [candidate.logPath], !candidate.isSubagent, candidate.isIdle)
            }
        }

        return order.prefix(maximumFiles).compactMap { id in
            guard let group = byID[id] else { return nil }
            return RunwaySessionIdentity(
                id: id,
                displayName: group.displayName,
                isGoal: false,
                logPaths: group.logPaths.sorted(),
                isIdle: group.isIdle
            )
        }
    }

    // The parse struct lives at file scope (not nested): a static stored
    // property whose generic argument is a type nested in the same declaration
    // trips a circular-reference error in the type checker.
    private static let fileCache = RunwayFileParseCache<ClaudeScannerFileParse>()

    #if DEBUG
    static var fileCacheMissCountForTesting: Int { fileCache.missCount }
    static func resetFileCacheForTesting() { fileCache.removeAllForTesting() }
    #endif

    private static func candidate(for url: URL, now: Date, signature: RunwayFileSignature) -> ScannedCandidate? {
        let parse = fileCache.value(path: url.path, signature: signature) {
            // Self-qualified: the unqualified name would bind to the local
            // `metadata` below and cycle the type checker.
            ClaudeScannerFileParse(
                metadata: Self.metadata(from: url),
                activeStateLines: activeStateLines(url: url)
            )
        }
        let metadata = parse.metadata
        if ClaudeProbeConfig.isProbeWorkingDirectory(metadata.cwd) {
            return nil
        }
        let state = activeState(from: parse.activeStateLines, now: now)
        guard state.active else { return nil }
        let fallbackID = url.deletingPathExtension().lastPathComponent
        let isSubagent = url.pathComponents.contains("subagents")
        // Subagents fold into the parent session for cumulative burn, but never
        // lend their internal task prompt as a name — use only the project
        // folder so the parent's real title always wins the merge.
        let name = isSubagent
            ? projectFallbackName(metadata: metadata, fallbackID: fallbackID)
            : displayName(metadata: metadata, fallbackID: fallbackID)
        return ScannedCandidate(
            id: metadata.sessionID ?? fallbackID,
            displayName: name,
            logPath: url.path,
            isSubagent: isSubagent,
            isIdle: state.isIdle
        )
    }

    private static func projectFallbackName(metadata: ClaudeScannerSessionMetadata, fallbackID: String) -> String {
        if let cwd = metadata.cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty {
            return compact(URL(fileURLWithPath: cwd).lastPathComponent)
        }
        return compact(fallbackID)
    }

    private struct ScannedCandidate {
        let id: String
        let displayName: String
        let logPath: String
        let isSubagent: Bool
        let isIdle: Bool
    }

    /// The expensive, `now`-independent half of the active-state read: tail the
    /// file and parse the last lines into `(capturedAt, idle)`. Lines without a
    /// valid object/timestamp are dropped exactly as the reverse scan would skip
    /// them, so this is byte-identical to inlining the parse. Cached per file.
    private static func activeStateLines(url: URL) -> [ClaudeScannerActiveStateLine] {
        guard let data = ClaudeRunwayLog.tailData(path: url.path, maxBytes: 256 * 1024),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(200)
        var result: [ClaudeScannerActiveStateLine] = []
        result.reserveCapacity(lines.count)
        for line in lines {
            guard let obj = ClaudeRunwayLog.jsonObject(String(line)),
                  let capturedAt = ClaudeRunwayLog.date(obj["timestamp"]) else {
                continue
            }
            result.append(ClaudeScannerActiveStateLine(capturedAt: capturedAt, idle: isIdleMarker(obj)))
        }
        return result
    }

    /// Whether the session is still on the runway, and whether its latest line
    /// shows it idle (finished its turn). Idle sessions use a shorter presence
    /// window and render a calm "—" instead of a spinner.
    ///
    /// Recomputed every cycle from the cached `lines`: the future-timestamp skip
    /// and the presence-window thresholds are the only `now`-dependencies, so
    /// state advances (active→idle→gone) as time passes with the disk unchanged.
    private static func activeState(from lines: [ClaudeScannerActiveStateLine], now: Date) -> (active: Bool, isIdle: Bool) {
        for line in lines.reversed() {
            // Skip lines with implausible future timestamps (clock skew / bad
            // data) rather than treating them as live activity.
            guard line.capturedAt <= now.addingTimeInterval(5) else { continue }
            // An idle session (finished its turn) drops sooner than a working
            // one so it doesn't linger as a stale row.
            let threshold = line.idle ? idleSessionGrace : maximumActiveSampleAge
            return (now.timeIntervalSince(line.capturedAt) <= threshold, line.idle)
        }
        return (false, false)
    }

    /// True when the newest line shows the session handed back to the user: an
    /// assistant message whose turn ended with `end_turn`/`stop_sequence`.
    /// Anything else (`tool_use`, `max_tokens`, `null`, or a non-assistant last
    /// line such as a tool result) means it is still working → not idle.
    private static func isIdleMarker(_ obj: [String: Any]) -> Bool {
        guard (obj["type"] as? String) == "assistant",
              let message = obj["message"] as? [String: Any],
              let stop = message["stop_reason"] as? String else {
            return false
        }
        return stop == "end_turn" || stop == "stop_sequence"
    }

    private static func metadata(from url: URL) -> ClaudeScannerSessionMetadata {
        guard let data = ClaudeRunwayLog.headData(path: url.path, maxBytes: 96 * 1024),
              let text = String(data: data, encoding: .utf8) else {
            return ClaudeScannerSessionMetadata()
        }
        var metadata = ClaudeScannerSessionMetadata()
        // Scan a healthy slice of the head: ai-title/custom-title records are
        // usually written a few turns in, after the first user message.
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(160) {
            guard let obj = ClaudeRunwayLog.jsonObject(String(line)) else { continue }
            if metadata.sessionID == nil { metadata.sessionID = string(obj["sessionId"]) }
            if metadata.cwd == nil { metadata.cwd = string(obj["cwd"]) }
            switch string(obj["type"]) {
            case "custom-title":
                // From /rename — authoritative, matches the app's title logic.
                if let title = string(obj["customTitle"]), !title.isEmpty { metadata.customTitle = title }
            case "ai-title":
                // Generated title; this is what Claude usually shows as the name.
                if metadata.aiTitle == nil, let title = string(obj["aiTitle"]), !title.isEmpty {
                    metadata.aiTitle = title
                }
            case "user":
                if metadata.firstUserText == nil,
                   let message = obj["message"] as? [String: Any],
                   string(message["role"]) == "user",
                   let text = userText(from: message["content"]),
                   !isSetupContextText(text) {
                    metadata.firstUserText = text
                }
            default:
                break
            }
        }
        return metadata
    }

    private static func displayName(metadata: ClaudeScannerSessionMetadata, fallbackID: String) -> String {
        // Mirror ClaudeSessionParser's preference: custom-title > ai-title >
        // first prompt > project folder. (Desktop-only titles that never land
        // in the transcript can't be recovered here.)
        for candidate in [metadata.customTitle, metadata.aiTitle, metadata.firstUserText] {
            if let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return compact(text)
            }
        }
        if let cwd = metadata.cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cwd.isEmpty {
            return compact(URL(fileURLWithPath: cwd).lastPathComponent)
        }
        return compact(fallbackID)
    }

    private static func userText(from content: Any?) -> String? {
        if let string = content as? String { return string }
        if let blocks = content as? [[String: Any]] {
            for block in blocks {
                if string(block["type"]) == "text", let text = string(block["text"]) {
                    return text
                }
            }
        }
        return nil
    }

    private static func isSetupContextText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let prefixes = ["<system-reminder>", "<command-", "<local-command", "Caveat:",
                        "# CLAUDE.md", "# AGENTS.md", "<environment_context>"]
        return prefixes.contains { trimmed.hasPrefix($0) }
    }

    private static func compact(_ text: String) -> String {
        ClaudeRunwayLog.compact(text)
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }
}

// MARK: - Cached parse artifacts (file scope)
// These are the scanner's per-file cache value types. They must live at file
// scope: `RunwayFileParseCache<CachedFileParse>` as a static stored property
// with a nested generic argument trips a circular-reference error in the
// type checker.

/// Bytes-derived, `now`-independent artifacts for one transcript file. Held
/// in the scanner's `fileCache` keyed by `(path, mtime, size)`; the
/// now-dependent active window is recomputed from `activeStateLines` on every
/// cycle.
private struct ClaudeScannerFileParse {
    let metadata: ClaudeScannerSessionMetadata
    let activeStateLines: [ClaudeScannerActiveStateLine]
}

private struct ClaudeScannerActiveStateLine {
    let capturedAt: Date
    let idle: Bool
}

private struct ClaudeScannerSessionMetadata {
    var sessionID: String?
    var cwd: String?
    var firstUserText: String?
    var customTitle: String?
    var aiTitle: String?
}

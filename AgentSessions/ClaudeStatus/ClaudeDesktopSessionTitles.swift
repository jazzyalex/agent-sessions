import Foundation

/// Reads the session titles shown in the Claude Desktop app.
///
/// Desktop keeps conversation metadata outside the CLI transcript, in
/// `~/Library/Application Support/Claude/claude-code-sessions/**/local_*.json`,
/// linked to the transcript by `cliSessionId`. That `title` is what the user
/// actually sees in the app (whether they renamed it or Claude generated it),
/// so the runway prefers it over anything derivable from the transcript.

struct ClaudeDesktopSidecarRecord: Equatable {
    let cliSessionID: String
    let title: String?
    let isArchived: Bool
    let autoArchiveExempt: Bool
    let sidecarPath: String
    let modifiedAt: Date
}

enum ClaudeDesktopSessionTitles {
    static func defaultRoot() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
    }

    /// Root of Cowork (local-agent mode) session metadata. Same `local_*.json`
    /// sidecar shape as `claude-code-sessions`, different tree.
    static func coworkRoot() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions", isDirectory: true)
    }

    /// The two sidecar roots every overlay consumer should read: Claude
    /// Desktop Code-tab sessions plus Cowork (local-agent mode).
    static func defaultRoots() -> [URL] {
        [defaultRoot(), coworkRoot()]
    }

    /// Directory names inside the Cowork tree that hold session artifacts
    /// (uploaded files, generated outputs, plugin bundles) — potentially
    /// thousands of entries, never sidecar metadata. Mirrors the skip list in
    /// `ClaudeSessionDiscovery.desktopLocalAgentRoots`. The nested `.claude`
    /// transcript dirs are already excluded by `.skipsHiddenFiles`.
    private static let skippedDirectoryNames: Set<String> =
        ["uploads", "outputs", "cowork_plugins", "skills-plugin"]

    /// Per-file-path cache entry: the parsed record plus the file mtime it was
    /// parsed from. Keyed by `root` so distinct roots (tests use per-test temp
    /// dirs) never share entries.
    private struct CacheEntry {
        var record: ClaudeDesktopSidecarRecord?
        var modifiedAt: Date
    }

    /// Guards `cacheByRoot` below. `records(root:fileManager:)` is called from
    /// main-actor call sites (transcript archive strip, HUD-adjacent archive
    /// overlay) and is also safe to call off-main (`ClaudeRunwaySnapshotLoader`
    /// already does, on a utility queue) — the lock makes the cache safe under both.
    private static let cacheLock = NSLock()
    private static var cacheByRoot: [URL: [String: CacheEntry]] = [:]
    #if DEBUG
    private static var debugParseCount = 0
    private static var debugCacheHitCount = 0
    #endif

    /// Map of CLI transcript session id -> full sidecar record. Last-writer-wins by mtime.
    ///
    /// Still walks the directory tree every call (`fileManager.enumerator` — a
    /// tree of unknown, possibly multi-level depth per the `**/local_*.json`
    /// layout, so there is no cheaper reliable "has anything changed" probe
    /// than visiting every entry's mtime). What's cached is the expensive part:
    /// per-file `Data(contentsOf:)` + `JSONSerialization` parsing is skipped
    /// for any file whose mtime matches what was parsed last time. On an
    /// unchanged tree this turns N JSON parses into N cheap mtime comparisons —
    /// this was measured running on the MAIN thread, once per HUD/
    /// transcript-archive-strip rebuild (W7 Task 2b).
    static func records(root: URL? = nil, fileManager: FileManager = .default) -> [String: ClaudeDesktopSidecarRecord] {
        let rootURL = root ?? defaultRoot()
        guard fileManager.fileExists(atPath: rootURL.path),
              let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else {
            cacheLock.lock()
            cacheByRoot[rootURL] = nil
            cacheLock.unlock()
            return [:]
        }

        cacheLock.lock()
        let previousCache = cacheByRoot[rootURL] ?? [:]
        cacheLock.unlock()

        var nextCache: [String: CacheEntry] = [:]
        nextCache.reserveCapacity(previousCache.count)
        var out: [String: ClaudeDesktopSidecarRecord] = [:]

        for case let url as URL in enumerator {
            if skippedDirectoryNames.contains(url.lastPathComponent),
               (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                enumerator.skipDescendants()
                continue
            }
            guard url.lastPathComponent.hasPrefix("local_"), url.pathExtension == "json" else { continue }
            let path = url.path
            let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast

            let record: ClaudeDesktopSidecarRecord?
            if let cached = previousCache[path], cached.modifiedAt == modifiedAt {
                record = cached.record
                #if DEBUG
                debugCacheHitCount += 1
                #endif
            } else {
                record = Self.parseRecord(at: url, modifiedAt: modifiedAt)
                #if DEBUG
                debugParseCount += 1
                #endif
            }
            nextCache[path] = CacheEntry(record: record, modifiedAt: modifiedAt)

            guard let record else { continue }
            if let existing = out[record.cliSessionID], existing.modifiedAt >= record.modifiedAt { continue }
            out[record.cliSessionID] = record
        }

        cacheLock.lock()
        cacheByRoot[rootURL] = nextCache
        cacheLock.unlock()

        return out
    }

    /// Merge of `records(root:)` across several roots. Duplicate `cliSessionId`s
    /// resolve last-writer-wins by sidecar mtime, matching the single-root rule.
    /// Each root keeps its own mtime cache entry (cache is keyed by root).
    static func records(roots: [URL], fileManager: FileManager = .default) -> [String: ClaudeDesktopSidecarRecord] {
        var merged: [String: ClaudeDesktopSidecarRecord] = [:]
        for rootURL in roots {
            for (cli, record) in records(root: rootURL, fileManager: fileManager) {
                if let existing = merged[cli], existing.modifiedAt >= record.modifiedAt { continue }
                merged[cli] = record
            }
        }
        return merged
    }

    private static func parseRecord(at url: URL, modifiedAt: Date) -> ClaudeDesktopSidecarRecord? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cli = (obj["cliSessionId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cli.isEmpty else {
            return nil
        }
        let rawTitle = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ClaudeDesktopSidecarRecord(
            cliSessionID: cli,
            title: (rawTitle?.isEmpty == false) ? rawTitle : nil,
            isArchived: (obj["isArchived"] as? Bool) ?? false,
            autoArchiveExempt: (obj["autoArchiveExempt"] as? Bool) ?? false,
            sidecarPath: url.path,
            modifiedAt: modifiedAt
        )
    }

    /// Map of CLI transcript session id -> Desktop title (trimmed, non-empty).
    static func map(root: URL? = nil, fileManager: FileManager = .default) -> [String: String] {
        var titles: [String: String] = [:]
        for (cli, rec) in records(root: root, fileManager: fileManager) {
            if let t = rec.title, !t.isEmpty { titles[cli] = t }
        }
        return titles
    }

    /// Test-only: clears the process-wide cache AND the parse/hit counters so
    /// tests using distinct temp directories don't observe a stale entry or
    /// stale counts from a prior test.
    #if DEBUG
    static func debugResetCache() {
        cacheLock.lock()
        cacheByRoot = [:]
        debugParseCount = 0
        debugCacheHitCount = 0
        cacheLock.unlock()
    }

    /// Cumulative counts since the last `debugResetCache()`: how many
    /// `local_*.json` files were freshly parsed vs served from the mtime cache.
    static func debugParseAndHitCounts() -> (parsed: Int, cacheHits: Int) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return (debugParseCount, debugCacheHitCount)
    }
    #endif
}

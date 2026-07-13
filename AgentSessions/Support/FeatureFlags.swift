import Foundation

enum FeatureFlags {
    // When true, search only uses prebuilt transcript cache; when false, it can
    // generate transcripts on demand to preserve correctness before cache warms.
    static let filterUsesCachedTranscriptOnly = false
    // Background indexing/ingest stays at .utility to remain a good system citizen.
    static let lowerQoSForBackgroundIngest = true
    // Shared accessors for the ~25 identical inline ternaries this flag used to
    // spawn across the indexers. Use `backgroundIngestQueue` for
    // `.receive(on:)`/`DispatchQueue.global(qos:)` call sites and
    // `backgroundIngestTaskPriority` for `Task(priority:)`/`Task.detached(priority:)`
    // call sites.
    static var backgroundIngestQueue: DispatchQueue {
        DispatchQueue.global(qos: lowerQoSForBackgroundIngest ? .utility : .userInitiated)
    }
    static var backgroundIngestTaskPriority: TaskPriority {
        lowerQoSForBackgroundIngest ? .utility : .userInitiated
    }
    // Interactive search runs at .userInitiated with no inter-batch sleep so typing stays responsive.
    static let lowerQoSForInteractiveSearch = false
    // Building the transcript for the session you just clicked is interactive: run it at
    // .userInitiated so it doesn't queue behind background indexing/prewarm (also .utility).
    static let lowerQoSForInteractiveTranscript = false
    // UnifiedSessionIndexer.recomputeNow() is fired exclusively by discrete user actions
    // (agent/source toggles, favorites-only, hideZero/hideLow/housekeeping, project-filter
    // clear, sort) -- never by background ingest, which drives the separate $allSessions
    // Combine pipeline that stays on backgroundIngestQueue. Run it at .userInitiated so a
    // filter toggle doesn't queue behind background ingest on large corpora. Precedent:
    // lowerQoSForInteractiveSearch above.
    static let lowerQoSForInteractiveFilterRecompute = false
    static var interactiveFilterRecomputeQueue: DispatchQueue {
        DispatchQueue.global(qos: lowerQoSForInteractiveFilterRecompute ? .utility : .userInitiated)
    }
    // recomputeNow()'s debounce exists to coalesce bursts of discrete toggle clicks, not to
    // throttle typing (typed queries flow through the separate $query Combine pipeline, not
    // recomputeNow()). A shorter window keeps single-click toggles snappy while still
    // coalescing rapid multi-clicks (e.g. unchecking several agent sources in a row).
    static let fastFilterRecomputeDebounce = true
    static let throttleIndexingUIUpdates = true
    static let gatePrewarmWhileTyping = true
    static let increaseFilterDebounce = true
    static let coalesceListResort = true
    // Stage 2 (search-specific)
    static let throttleSearchUIUpdates = true
    static let coalesceSearchResults = true
    static let increaseDeepSearchDebounce = true
    static let offloadTranscriptBuildInView = true
    static let enableFTSSearch = true
    static let ftsSearchLimit: Int = 2_000
    static let instantToolOutputIndexMaxChars: Int = 12_000
    static let sessionSearchFormatVersion: Int = 4
    static let sessionToolIOFormatVersion: Int = 1
    static let transcriptPrewarmMaxSessionsPerRefresh: Int = 96
    static let transcriptPrewarmMaxSessionBytes: Int = 50 * 1024 * 1024

    // Tool I/O FTS index (recent window + retention cap for older rows).
    static let toolIOIndexRecentDays: Int = 30
    static let toolIOIndexOldBytesCap: Int64 = 8 * 1024 * 1024
    static let toolIOIndexMaxCharsPerSession: Int = 120_000
    static let toolIOIndexMaxCharsPerEvent: Int = 32_000

    static let searchSmallSizeBytes: Int = 10 * 1024 * 1024

    // Avoid pushing parsed session updates back to indexers during an active
    // search to reduce MainActor churn and improve responsiveness.
    static let disableSessionUpdatesDuringSearch = true

    // Gate Codex tmux-based /status probes (secondary source).
    // Re-enabled: probes run only when stale (or via explicit hard-probe button).
    static let disableCodexProbes = false

    // Allow deleting only AS-generated Codex probe sessions (strict project match).
    // General Codex session deletion remains forbidden by the cleanup gate.
    static let allowCodexProbeDeletion = true

    // Phase 2+ progressive windowed transcript build. When false, the line/block
    // model uses today's local (slice-relative) identities — byte-for-byte
    // unchanged. When true, lines/blocks derive stable GLOBAL identities so a
    // later prepended window never renumbers existing lines. Default false until
    // parity-gated. (Phase 3 also gates the windowed build-on-open on this flag.)
    // Default ON since 2026-07-02: parity-gated against the whole-session build
    // (Terminal/Transcript/Golden suites green in both states) and QA'd on a
    // 49k-event session (windowed first paint, char-gated swap, monsters never
    // full-apply).
    static let transcriptWindowedBuild = true
    // Target number of WHOLE coalesced blocks per window. The window is expanded
    // outward to whole-block boundaries, so the realized line count varies with
    // block sizes; this bounds the block count, not the line count.
    static let transcriptWindowBlockTarget: Int = 400
    // When true, scrolling near the transcript top loads the previous (older) window.
    static let transcriptWindowNearTopLoadOlder = true

    // Two-stage open: after the windowed first paint, the full-session build is
    // swapped in ONLY when total transcript characters are at or below this
    // threshold. Applying content costs main-thread time proportional to
    // characters (attr build + setAttributedString + layout), so an unbounded
    // swap would reintroduce a beachball on monster sessions. Tune with the
    // transcriptSwapApply perf span.
    static let transcriptFullSwapMaxChars: Int = 800_000

    // Task 9e stage 0: tail-first cold paint. On selecting an unhydrated Codex
    // session whose file exceeds transcriptTailFirstPaintMinBytes, publish a
    // disposable provisional session built from just the last window of the
    // file (ReverseJSONLTailReader + parseFileTail) so something readable
    // appears in well under a second, THEN run the normal full parse exactly
    // as today. The provisional content is throwaway: when the full parse
    // publishes, events.count changes and the existing two-stage rebuild
    // (transcriptWindowedBuild's onChange(session.events.count) path) swaps
    // it out wholesale. Requires transcriptWindowedBuild=true for that
    // replacing swap to itself be windowed (cheap) rather than a full
    // non-windowed rebuild of 49k+ lines on the main thread.
    // Default ON since 2026-07-02: QA'd cold-open of a 200MB/49k-event session —
    // tail content in ~200ms of pipeline work while the full parse (~11s)
    // continues in the background and the two-stage swap replaces the
    // provisional paint.
    // The dependency on transcriptWindowedBuild is enforced structurally below
    // (not just documented): the public accessor ANDs the raw stored flag with
    // transcriptWindowedBuild, so tail-first paint can never be effectively "on"
    // while windowed build is "off" — that combination would make the
    // replacing swap a full, non-windowed rebuild of 49k+ lines on the main
    // thread instead of the cheap windowed one.
    private static let transcriptTailFirstPaintRaw = true
    static var transcriptTailFirstPaint: Bool {
        transcriptTailFirstPaintRaw && transcriptWindowedBuild
    }
    static let transcriptTailFirstPaintMinBytes: Int = 8_000_000

}

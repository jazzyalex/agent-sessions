import Foundation

enum FeatureFlags {
    // When true, search only uses prebuilt transcript cache; when false, it can
    // generate transcripts on demand to preserve correctness before cache warms.
    static let filterUsesCachedTranscriptOnly = false
    // Background indexing/ingest stays at .utility to remain a good system citizen.
    static let lowerQoSForBackgroundIngest = true
    // Interactive search runs at .userInitiated with no inter-batch sleep so typing stays responsive.
    static let lowerQoSForInteractiveSearch = false
    // Building the transcript for the session you just clicked is interactive: run it at
    // .userInitiated so it doesn't queue behind background indexing/prewarm (also .utility).
    static let lowerQoSForInteractiveTranscript = false
    // Large-session guardrail: above either limit, skip auto parse/build on selection and
    // show a "Show full transcript" affordance, so a monster session can't hang the app.
    static let largeSessionMessageThreshold: Int = 5_000
    static let largeSessionByteThreshold: Int = 25 * 1024 * 1024
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
    // parity-gated.
    static let transcriptWindowedBuild = false

}

import Foundation

enum FeatureFlags {
    // When true, search only uses prebuilt transcript cache; when false, it can
    // generate transcripts on demand to preserve correctness before cache warms.
    static let filterUsesCachedTranscriptOnly = false
    static let lowerQoSForHeavyWork = true
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
    static let instantToolOutputIndexMaxChars: Int = 32_000
    static let sessionSearchFormatVersion: Int = 4
    static let sessionToolIOFormatVersion: Int = 1

    // Tool I/O FTS index (recent window + retention cap for older rows).
    static let toolIOIndexRecentDays: Int = 90
    static let toolIOIndexOldBytesCap: Int64 = 25 * 1024 * 1024
    static let toolIOIndexMaxCharsPerSession: Int = 500_000
    static let toolIOIndexMaxCharsPerEvent: Int = 200_000

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
}

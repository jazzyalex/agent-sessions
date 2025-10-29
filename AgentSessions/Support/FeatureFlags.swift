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

    static let searchSmallSizeBytes: Int = 10 * 1024 * 1024

    // Avoid pushing parsed session updates back to indexers during an active
    // search to reduce MainActor churn and improve responsiveness.
    static let disableSessionUpdatesDuringSearch = true

    // Analytics: disable Tool Calls computation to keep UI fast
    static let disableToolCallsCard = true
}

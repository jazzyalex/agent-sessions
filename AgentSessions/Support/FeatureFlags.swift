import Foundation

enum FeatureFlags {
    static let filterUsesCachedTranscriptOnly = true
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
}

import Foundation

enum ImageBrowserPerfMetrics {
    #if DEBUG
    private static var openTappedAt: Date?
    private static var windowShownAt: Date?
    private static var selectedIndexReadyAt: Date?

    static func markOpenTapped() {
        openTappedAt = Date()
        windowShownAt = nil
        selectedIndexReadyAt = nil
    }

    static func markWindowShown() {
        windowShownAt = Date()
        logDelta(label: "window_shown", from: openTappedAt, to: windowShownAt)
    }

    static func markSelectedIndexReady(imageCount: Int) {
        selectedIndexReadyAt = Date()
        logDelta(label: "selected_index_ready(\(imageCount))", from: openTappedAt, to: selectedIndexReadyAt)
    }

    static func markFirstThumbnailShown() {
        logDelta(label: "first_thumbnail", from: openTappedAt, to: Date())
    }

    static func logBackgroundProgress(scannedSessions: Int, totalSessions: Int) {
        print("[ImageBrowserPerf] background_index \(scannedSessions)/\(totalSessions)")
    }

    private static func logDelta(label: String, from: Date?, to: Date?) {
        guard let from, let to else { return }
        let ms = Int((to.timeIntervalSince(from) * 1000.0).rounded())
        print("[ImageBrowserPerf] \(label)=\(ms)ms")
    }
    #else
    static func markOpenTapped() {}
    static func markWindowShown() {}
    static func markSelectedIndexReady(imageCount: Int) {}
    static func markFirstThumbnailShown() {}
    static func logBackgroundProgress(scannedSessions: Int, totalSessions: Int) {}
    #endif
}


import Foundation

enum ImageBrowserPerfMetrics {
    #if DEBUG
    private actor State {
        var openTappedAt: Date?
        var windowShownAt: Date?
        var selectedIndexReadyAt: Date?

        func markOpenTapped() {
            openTappedAt = Date()
            windowShownAt = nil
            selectedIndexReadyAt = nil
        }

        func markWindowShown() {
            windowShownAt = Date()
            logDelta(label: "window_shown", from: openTappedAt, to: windowShownAt)
        }

        func markSelectedIndexReady(imageCount: Int) {
            selectedIndexReadyAt = Date()
            logDelta(label: "selected_index_ready(\(imageCount))", from: openTappedAt, to: selectedIndexReadyAt)
        }

        func markFirstThumbnailShown() {
            logDelta(label: "first_thumbnail", from: openTappedAt, to: Date())
        }

        private func logDelta(label: String, from: Date?, to: Date?) {
            guard let from, let to else { return }
            let ms = Int((to.timeIntervalSince(from) * 1000.0).rounded())
            print("[ImageBrowserPerf] \(label)=\(ms)ms")
        }
    }

    private static let state = State()

    static func markOpenTapped() {
        Task {
            await state.markOpenTapped()
        }
    }

    static func markWindowShown() {
        Task {
            await state.markWindowShown()
        }
    }

    static func markSelectedIndexReady(imageCount: Int) {
        Task {
            await state.markSelectedIndexReady(imageCount: imageCount)
        }
    }

    static func markFirstThumbnailShown() {
        Task {
            await state.markFirstThumbnailShown()
        }
    }

    static func logBackgroundProgress(scannedSessions: Int, totalSessions: Int) {
        print("[ImageBrowserPerf] background_index \(scannedSessions)/\(totalSessions)")
    }
    #else
    static func markOpenTapped() {}
    static func markWindowShown() {}
    static func markSelectedIndexReady(imageCount: Int) {}
    static func markFirstThumbnailShown() {}
    static func logBackgroundProgress(scannedSessions: Int, totalSessions: Int) {}
    #endif
}

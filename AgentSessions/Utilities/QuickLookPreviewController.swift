import AppKit
import QuickLookUI

final class QuickLookPreviewController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookPreviewController()

    private let lock = NSLock()
    private var urls: [URL] = []
    private var selectedIndex: Int = 0

    @MainActor
    func preview(urls: [URL], selectedIndex: Int = 0) {
        lock.lock()
        self.urls = urls
        self.selectedIndex = max(0, min(selectedIndex, urls.count - 1))
        lock.unlock()

        guard !urls.isEmpty else { return }
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.currentPreviewItemIndex = self.selectedIndex
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        lock.lock()
        let count = urls.count
        lock.unlock()
        return count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        lock.lock()
        let url = urls[index]
        lock.unlock()
        return url as NSURL
    }
}

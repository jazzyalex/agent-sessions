import SwiftUI
import AppKit

/// Finds the nearest NSSplitView ancestor and sets an autosave name
/// so divider position persists across relaunches.
struct SplitViewAutosave: NSViewRepresentable {
    let key: String

    func makeNSView(context: Context) -> NSView {
        let v = SplitFinderView(key: key)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class SplitFinderView: NSView {
    private let key: String
    init(key: String) { self.key = key; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.apply() }
    }

    private func apply() {
        guard let split = findSplitView(from: self) else { return }
        if split.autosaveName != key {
            split.autosaveName = key
        }
    }

    private func findSplitView(from start: NSView?) -> NSSplitView? {
        var v = start?.superview
        while let cur = v {
            if let s = cur as? NSSplitView { return s }
            v = cur.superview
        }
        return nil
    }
}


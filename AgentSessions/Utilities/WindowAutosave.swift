import SwiftUI
import AppKit

/// Attaches to the view hierarchy and configures the hosting NSWindow
/// with an autosave name so frame/position persist across relaunches.
struct WindowAutosave: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let win = v.window else { return }
            // Configure once
            if win.frameAutosaveName != name {
                win.setFrameAutosaveName(name)
                win.isRestorable = true
            }
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // No-op
    }
}


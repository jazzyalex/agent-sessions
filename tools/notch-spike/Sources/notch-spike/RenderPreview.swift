import AppKit
import SwiftUI

/// `NOTCH_SPIKE_RENDER=<dir>`: render the notch view states to PNG over a fake menu bar, then exit.
@MainActor
enum RenderPreview {
    static func runIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["NOTCH_SPIKE_RENDER"] else { return }
        let base = URL(fileURLWithPath: dir)
        for (name, notchWidth, height, virtual) in [("notch", 184.0, 32.0, false), ("lg", 24.0, 25.0, true)] {
            for expanded in [false, true] {
                let model = NotchModel(notchWidth: notchWidth, notchHeight: height, virtual: virtual)
                model.expanded = expanded
                let view = ZStack(alignment: .top) {
                    LinearGradient(colors: [Color(red: 0.30, green: 0.42, blue: 0.62),
                                            Color(red: 0.62, green: 0.48, blue: 0.58)],
                                   startPoint: .top, endPoint: .bottom)
                    Rectangle().fill(.white.opacity(0.35)).frame(height: height)
                    if !virtual {
                        Rectangle().fill(.black).frame(width: notchWidth, height: height)
                    }
                    NotchRootView(model: model)
                }
                .frame(width: model.panelSize.width, height: model.panelSize.height)
                render(view, to: base.appending(path: "\(name)-\(expanded ? "open" : "closed").png"))
            }
        }
        exit(0)
    }

    private static func render(_ view: some View, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}

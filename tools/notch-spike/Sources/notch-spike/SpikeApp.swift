import AppKit
import SwiftUI
import NotchSpikeCore

/// The spike shows only the notch strip. Switching to the floating window is a toggle to the
/// app's existing Quota Meter, tested in the real app, so the spike has no floating window.
@main
struct SpikeApp: App {
    @NSApplicationDelegateAdaptor(SpikeAppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class SpikeAppDelegate: NSObject, NSApplicationDelegate {
    private(set) var controller: SpikeController?
    private(set) var menu: SpikeMenu?

    /// Terminal commands, so marking a checklist step never activates the spike:
    /// `mark <id>`, `wings`, `minimal`, `quit`.
    private func readCommands(controller: SpikeController) {
        Thread.detachNewThread {
            while let line = readLine() {
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                guard let command = parts.first else { continue }
                let argument = parts.count > 1 ? parts[1].replacingOccurrences(of: " ", with: "_") : "-"
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        switch command {
                        case "mark": SpikeLog.shared.write("mark", ["label": argument, "source": "stdin"])
                        case "wings": controller.style = .wings
                        case "minimal": controller.style = .minimal
                        case "quit":
                            SpikeLog.shared.write("quit")
                            SpikeLog.shared.flushForTesting()
                            NSApp.terminate(nil)
                        default: print("commands: mark <id> | wings | minimal | quit")
                        }
                    }
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        RenderPreview.runIfRequested()
        NSApp.setActivationPolicy(.accessory)
        SpikeLog.shared.write("launch", ["pid": String(ProcessInfo.processInfo.processIdentifier)])
        let controller = SpikeController(log: .shared)
        self.controller = controller
        controller.start()
        let menu = SpikeMenu(controller: controller, log: .shared)
        self.menu = menu
        controller.menuProvider = { [weak menu] in menu?.menu }
        readCommands(controller: controller)
    }
}

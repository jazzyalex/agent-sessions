import AppKit
import SwiftUI
import NotchSpikeCore

@main
struct SpikeApp: App {
    @NSApplicationDelegateAdaptor(SpikeAppDelegate.self) private var delegate

    var body: some Scene {
        Window("Stand-in", id: StandInRouter.identifier) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Floating stand-in").font(.headline)
                Text("Codex 62%  ·  Claude 34%").font(.system(.body, design: .monospaced))
            }
            .padding(16)
            .frame(width: 380, height: 120, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.85)))
            .foregroundStyle(.white)
            .background(StandInWindowConfigurator(log: .shared))
            .background(StandInRegistration())
        }
        .windowResizability(.contentSize)

        Settings { EmptyView() }
    }
}

final class SpikeAppDelegate: NSObject, NSApplicationDelegate {
    private(set) var controller: SpikeController?
    private(set) var menu: SpikeMenu?
    private(set) var handoff: SpikeHandoff?

    /// Terminal commands, so marking a step never activates the spike and works
    /// even when the "NS" item is hidden behind the notch:
    /// `mark <id>`, `floating`, `notch`, `wings`, `minimal`, `quit`.
    private func readCommands(controller: SpikeController, handoff: SpikeHandoff) {
        Thread.detachNewThread {
            while let line = readLine() {
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                guard let command = parts.first else { continue }
                let argument = parts.count > 1 ? parts[1].replacingOccurrences(of: " ", with: "_") : "-"
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        switch command {
                        case "mark": SpikeLog.shared.write("mark", ["label": argument, "source": "stdin"])
                        case "floating": handoff.toFloating()
                        case "notch": handoff.toNotch()
                        case "wings": controller.style = .wings
                        case "minimal": controller.style = .minimal
                        case "quit":
                            SpikeLog.shared.write("quit")
                            SpikeLog.shared.flushForTesting()
                            NSApp.terminate(nil)
                        default: print("commands: mark <id> | floating | notch | wings | minimal | quit")
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
        let handoff = SpikeHandoff(controller: controller, log: .shared) {
            guard let open = StandInRouter.open else { return false }
            open()
            return true
        }
        self.handoff = handoff
        let menu = SpikeMenu(controller: controller, log: .shared)
        menu.onHandoffToFloating = { handoff.toFloating() }
        menu.onHandoffToNotch = { handoff.toNotch() }
        self.menu = menu
        controller.menuProvider = { [weak menu] in menu?.menu }
        readCommands(controller: controller, handoff: handoff)
        // Agent-side log-shape check without menu clicks.
        if ProcessInfo.processInfo.environment["NOTCH_SPIKE_AUTOHANDOFF"] == "1" {
            SpikeLog.shared.write("autohandoff")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { handoff.toFloating() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { handoff.toNotch() }
        }
    }
}
